#!/usr/bin/env bash
# Usage: ./scripts/run-azure.sh
# First-run only: export AZURE_DEVOPS_EXT_GITHUB_PAT=<github-pat> to create the pipeline.
# GitHub PAT scopes required: repo, admin:repo_hook, user
# Requires: az cli with devops extension (az extension add --name azure-devops)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/azure"
ITERATIONS="${ITERATIONS:-1}"
AZDO_ORG="${AZDO_ORG:-balon-thesis}"
AZDO_PROJECT="${AZDO_PROJECT:-thesis}"
PIPELINE_NAME="thesis-playwright-tests"

az devops configure --defaults \
  "organization=https://dev.azure.com/$AZDO_ORG" \
  "project=$AZDO_PROJECT"

tg() { (cd "$TF_DIR" && terragrunt "$@"); }

# Cluster metadata — mirrors infrastructure/root.hcl and infrastructure/azure/aks.tf
K8S_VERSION=$(awk -F'"' '/k8s_version/{print $2}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_COUNT=$(awk '/node_count/{print $3}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_TYPE="Standard_D2ads_v5"
LB_TYPE="azure-lb"
RUNNER_TYPE="azure-pipelines"

ensure_pipeline() {
  if az pipelines show --name "$PIPELINE_NAME" --output none 2>/dev/null; then
    echo "  Pipeline '$PIPELINE_NAME' already exists"
    return
  fi
  echo "ERROR: Pipeline '$PIPELINE_NAME' not found in Azure DevOps project '$AZDO_PROJECT'."
  echo "  Create it once manually:"
  echo "  1. Go to https://dev.azure.com/$AZDO_ORG/$AZDO_PROJECT/_build"
  echo "  2. New pipeline → GitHub (YAML) → asuujx/master-thesis"
  echo "  3. Existing YAML file: /pipelines/azure/azure-pipelines.yml"
  echo "  4. Save (don't run), then rename to '$PIPELINE_NAME'"
  exit 1
}

cleanup() {
  echo "==> Destroying Azure infrastructure..."
  tg destroy -auto-approve
}
trap cleanup EXIT

SUB="76287223-e5f3-4a6e-8897-3f42dac962d7"
STORAGE_SUFFIX="pb01"

try_import() {
  tg import "$1" "$2" 2>/dev/null \
    && echo "  reconciled: $1" || true
}

echo "==> Initializing Terragrunt..."
tg init -input=false

echo "==> Reconciling pre-existing Azure resources..."
try_import azurerm_resource_group.main \
  "/subscriptions/$SUB/resourceGroups/thesis-rg"
try_import azurerm_virtual_network.main \
  "/subscriptions/$SUB/resourceGroups/thesis-rg/providers/Microsoft.Network/virtualNetworks/thesis-vnet"
try_import azurerm_subnet.nodes \
  "/subscriptions/$SUB/resourceGroups/thesis-rg/providers/Microsoft.Network/virtualNetworks/thesis-vnet/subnets/thesis-nodes-subnet"
try_import azurerm_kubernetes_cluster.main \
  "/subscriptions/$SUB/resourceGroups/thesis-rg/providers/Microsoft.ContainerService/managedClusters/thesis-cluster"
try_import azurerm_storage_account.artifacts \
  "/subscriptions/$SUB/resourceGroups/thesis-rg/providers/Microsoft.Storage/storageAccounts/thesisartifacts${STORAGE_SUFFIX}"
try_import azurerm_storage_container.artifacts \
  "https://thesisartifacts${STORAGE_SUFFIX}.blob.core.windows.net/artifacts"

echo "==> Provisioning Azure infrastructure..."
tg apply -auto-approve -input=false

RG=$(tg output -raw resource_group_name)
CLUSTER=$(tg output -raw aks_cluster_name)
STORAGE_ACCOUNT=$(tg output -raw artifacts_storage_account)
STORAGE_KEY=$(tg output -raw storage_account_key)

echo "==> Configuring kubectl for AKS cluster $CLUSTER..."
az aks get-credentials --resource-group "$RG" --name "$CLUSTER" --overwrite-existing

echo "==> Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> Deploying app..."
kubectl apply -f "$REPO_ROOT/app/manifests/kubernetes-manifests.yaml"

echo "==> Waiting for frontend deployment..."
kubectl rollout status deployment/frontend --timeout=300s

echo "==> Waiting for LoadBalancer IP..."
IP=""
for i in $(seq 1 30); do
  IP=$(kubectl get service frontend-external \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$IP" ] && break
  echo "  attempt $i/30, retrying in 20s..."
  sleep 20
done
[ -z "$IP" ] && { echo "ERROR: LoadBalancer IP not assigned after 10 minutes"; exit 1; }
BASE_URL="http://$IP"
echo "==> App URL: $BASE_URL"

ensure_pipeline

DATETIME=$(date +%Y-%m-%d_%H-%M-%S)

for i in $(seq 1 "$ITERATIONS"); do
  echo "==> Running test iteration $i/$ITERATIONS..."
  RUN_ID=$(az pipelines run \
    --name "$PIPELINE_NAME" \
    --parameters "baseUrl=$BASE_URL" "iteration=$i" \
    --variables "STORAGE_ACCOUNT_NAME=$STORAGE_ACCOUNT" "STORAGE_ACCOUNT_KEY=$STORAGE_KEY" \
      "NODE_TYPE=$NODE_TYPE" "NODE_COUNT=$NODE_COUNT" "K8S_VERSION=$K8S_VERSION" \
      "CLUSTER_REGION=germanywestcentral" "LB_TYPE=$LB_TYPE" "RUNNER_TYPE=$RUNNER_TYPE" \
    --query "id" --output tsv)
  echo "  Pipeline run ID: $RUN_ID"

  STATUS="inProgress"
  while [ "$STATUS" = "inProgress" ] || [ "$STATUS" = "notStarted" ]; do
    sleep 30
    STATUS=$(az pipelines runs show --id "$RUN_ID" --query "status" --output tsv)
    echo "  Status: $STATUS"
  done

  RESULT=$(az pipelines runs show --id "$RUN_ID" --query "result" --output tsv)
  [ "$RESULT" != "succeeded" ] && echo "WARNING: iteration $i finished with result $RESULT"

  echo "==> Downloading metrics for iteration $i..."
  METRICS_DIR="$REPO_ROOT/metrics/azure/$DATETIME/iteration-$i"
  mkdir -p "$METRICS_DIR"
  TMP_DL=$(mktemp -d)
  if az storage blob download-batch \
       --account-name "$STORAGE_ACCOUNT" \
       --account-key "$STORAGE_KEY" \
       --source artifacts \
       --destination "$TMP_DL" \
       --pattern "runs/$RUN_ID/results/*"; then
    find "$TMP_DL" -name "*.json" -exec cp {} "$METRICS_DIR/" \;
    echo "  Saved to $METRICS_DIR ($(find "$METRICS_DIR" -name '*.json' | wc -l | tr -d ' ') file(s))"
  else
    echo "  WARNING: metrics download failed — check storage account $STORAGE_ACCOUNT, container artifacts"
  fi
  rm -rf "$TMP_DL"
done

echo "==> Generating summary..."
node "$REPO_ROOT/scripts/summarize.js" "$REPO_ROOT/metrics/azure/$DATETIME"

echo "==> All $ITERATIONS iteration(s) complete."

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

# Cluster metadata — read from terragrunt/root.hcl so metadata cannot drift from deployed config.
K8S_VERSION=$(awk -F'"' '/k8s_version/{print $2}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_COUNT=$(awk '/node_count/{print $3; exit}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_TYPE=$(awk -F'"' '/node_vm_size/{print $2}' "$TF_DIR/terragrunt.hcl")
SUB=$(awk -F'"' '/subscription_id/{print $2}' "$TF_DIR/terragrunt.hcl")
STORAGE_SUFFIX=$(awk -F'"' '/storage_suffix/{print $2}' "$TF_DIR/terragrunt.hcl")
AZURE_REGION=$(awk -F'"' '/azure_region/{print $2}' "$TF_DIR/terragrunt.hcl")
LB_TYPE="azure-lb"
RUNNER_TYPE="azure-pipelines"

# Convert ISO 8601 timestamp to Unix epoch seconds. Returns 0 on empty/invalid input.
iso_to_epoch() {
  [ -z "${1:-}" ] || [ "$1" = "None" ] && { echo 0; return; }
  python3 -c "import sys,datetime; s=sys.argv[1].strip().replace('Z','+00:00'); print(int(datetime.datetime.fromisoformat(s).timestamp()) if s else 0)" "$1" 2>/dev/null || echo 0
}

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
  # AKS LoadBalancer service creates resources in the auto-managed node resource group.
  # Drain the Service first so destroy doesn't race against it.
  echo "==> Removing Kubernetes LoadBalancer service..."
  kubectl delete service frontend-external --ignore-not-found=true --timeout=120s 2>/dev/null || true

  echo "==> Destroying Azure infrastructure..."
  tg destroy -auto-approve

  # Defensive: AKS normally deletes its node RG with the cluster, but if destroy timed out
  # or the LB had a stuck finalizer, the node RG can leak with a Standard LB + Public IP attached.
  NODE_RG="MC_thesis-rg_thesis-cluster_${AZURE_REGION}"
  if az group show --name "$NODE_RG" --output none 2>/dev/null; then
    echo "==> Removing orphaned AKS node resource group $NODE_RG..."
    az group delete --name "$NODE_RG" --yes --no-wait 2>/dev/null || true
  fi
}
trap cleanup EXIT

try_import() {
  tg import "$1" "$2" 2>/dev/null \
    && echo "  reconciled: $1" || true
}

echo "==> Validating Azure DevOps pipeline exists (fail-fast before provisioning)..."
ensure_pipeline

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
PROVISION_START=$SECONDS
tg apply -auto-approve -input=false
PROVISION_DURATION=$((SECONDS - PROVISION_START))

RG=$(tg output -raw resource_group_name)
CLUSTER=$(tg output -raw aks_cluster_name)
STORAGE_ACCOUNT=$(tg output -raw artifacts_storage_account)
STORAGE_KEY=$(tg output -raw storage_account_key)

echo "==> Configuring kubectl for AKS cluster $CLUSTER..."
az aks get-credentials --resource-group "$RG" --name "$CLUSTER" --overwrite-existing

echo "==> Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> Deploying app..."
DEPLOY_START=$SECONDS
kubectl apply -f "$REPO_ROOT/app/manifests/kubernetes-manifests.yaml"
# LB_START captures Service object creation, when AKS begins LB provisioning. This runs
# in parallel with the deployment, so DEPLOY_DURATION and LB_DURATION overlap by design.
LB_START=$SECONDS

echo "==> Waiting for frontend deployment..."
kubectl rollout status deployment/frontend --timeout=300s
DEPLOY_DURATION=$((SECONDS - DEPLOY_START))

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
LB_DURATION=$((SECONDS - LB_START))
BASE_URL="http://$IP"
echo "==> App URL: $BASE_URL"

echo "==> Waiting 30s for all pods to reach steady state..."
sleep 30

DATETIME=$(date +%Y-%m-%d_%H-%M-%S)
SUITE_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SUITE_START_S=$SECONDS

for i in $(seq 1 "$ITERATIONS"); do
  METRICS_DIR="$REPO_ROOT/metrics/azure/$DATETIME/iteration-$i"
  mkdir -p "$METRICS_DIR"

  echo "==> Capturing Kubernetes metrics before iteration $i..."
  bash "$REPO_ROOT/scripts/metrics/capture-kube-metrics.sh" "before" "$METRICS_DIR/kube_metrics_before.json" \
    || echo "  WARNING: kube metrics capture failed"

  echo "==> Running test iteration $i/$ITERATIONS..."
  SUBMIT_TS=$(date +%s)
  RUN_ID=$(az pipelines run \
    --name "$PIPELINE_NAME" \
    --parameters "baseUrl=$BASE_URL" "iteration=$i" \
    --variables "STORAGE_ACCOUNT_NAME=$STORAGE_ACCOUNT" "STORAGE_ACCOUNT_KEY=$STORAGE_KEY" \
      "NODE_TYPE=$NODE_TYPE" "NODE_COUNT=$NODE_COUNT" "K8S_VERSION=$K8S_VERSION" \
      "CLUSTER_REGION=$AZURE_REGION" "LB_TYPE=$LB_TYPE" "RUNNER_TYPE=$RUNNER_TYPE" \
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

  # Capture runner queue/execution time from Azure Pipelines API. queueTime = when run was queued;
  # startTime = when an agent picked it up; finishTime = completion. Pipeline-side install/test
  # timings are downloaded as part of runner_timings.json.
  RUNNER_QUEUE_ISO=$(az pipelines runs show --id "$RUN_ID" --query "queueTime" --output tsv 2>/dev/null || echo "")
  RUNNER_START_ISO=$(az pipelines runs show --id "$RUN_ID" --query "startTime" --output tsv 2>/dev/null || echo "")
  RUNNER_END_ISO=$(az pipelines runs show --id "$RUN_ID" --query "finishTime" --output tsv 2>/dev/null || echo "")
  RUNNER_QUEUE=$(iso_to_epoch "$RUNNER_QUEUE_ISO")
  RUNNER_START=$(iso_to_epoch "$RUNNER_START_ISO")
  RUNNER_END=$(iso_to_epoch "$RUNNER_END_ISO")
  if [ "$RUNNER_START" -gt 0 ] && [ "$RUNNER_END" -gt 0 ] && [ "$RUNNER_QUEUE" -gt 0 ]; then
    RUNNER_QUEUE_SECONDS=$((RUNNER_START - RUNNER_QUEUE))
    RUNNER_EXEC_SECONDS=$((RUNNER_END - RUNNER_START))
  else
    RUNNER_QUEUE_SECONDS=-1
    RUNNER_EXEC_SECONDS=-1
  fi
  cat > "$METRICS_DIR/provider_timings.json" << TIMINGS_EOF
{
  "submitEpoch": $SUBMIT_TS,
  "runnerQueueIso": "$RUNNER_QUEUE_ISO",
  "runnerStartIso": "$RUNNER_START_ISO",
  "runnerEndIso": "$RUNNER_END_ISO",
  "runnerQueueSeconds": $RUNNER_QUEUE_SECONDS,
  "runnerExecutionSeconds": $RUNNER_EXEC_SECONDS
}
TIMINGS_EOF

  echo "==> Downloading metrics for iteration $i..."
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

  echo "==> Capturing Kubernetes metrics after iteration $i..."
  bash "$REPO_ROOT/scripts/metrics/capture-kube-metrics.sh" "after" "$METRICS_DIR/kube_metrics_after.json" \
    || echo "  WARNING: kube metrics capture failed"
done

SUITE_DURATION=$((SECONDS - SUITE_START_S))
SUITE_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "==> Generating summary..."
node "$REPO_ROOT/scripts/metrics/summarize.js" "$REPO_ROOT/metrics/azure/$DATETIME"

echo "==> Writing run metadata..."
cat > "$REPO_ROOT/metrics/azure/$DATETIME/run_metadata.json" << METADATA_EOF
{
  "cloud": "azure",
  "environment": "aks",
  "nodeType": "$NODE_TYPE",
  "nodeCount": $NODE_COUNT,
  "k8sVersion": "$K8S_VERSION",
  "clusterRegion": "$AZURE_REGION",
  "lbType": "$LB_TYPE",
  "runnerType": "$RUNNER_TYPE",
  "iterationCount": $ITERATIONS,
  "suiteStartUtc": "$SUITE_START_UTC",
  "suiteEndUtc": "$SUITE_END_UTC",
  "infrastructureProvisioningSeconds": $PROVISION_DURATION,
  "appDeploySeconds": $DEPLOY_DURATION,
  "lbReadySeconds": $LB_DURATION,
  "totalTestSuiteDurationSeconds": $SUITE_DURATION
}
METADATA_EOF

echo "==> All $ITERATIONS iteration(s) complete."

#!/usr/bin/env bash
# Usage: ITERATIONS=5 ./scripts/run-gcp.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/gcp"
ITERATIONS="${ITERATIONS:-1}"

# Read static identifiers from terragrunt.hcl so imports work before apply.
PROJECT=$(awk -F'"' '/project_id/{print $2}' "$TF_DIR/terragrunt.hcl")
REGION=$(awk -F'"' '/gcp_region/{print $2}' "$TF_DIR/terragrunt.hcl")
ZONE="${REGION}-c"

tg() { (cd "$TF_DIR" && terragrunt "$@"); }

cleanup() {
  echo "==> Destroying GCP infrastructure..."
  tg destroy -auto-approve
}
trap cleanup EXIT

echo "==> Initializing Terragrunt..."
tg init -input=false

# Import any resources that already exist in GCP but aren't in state.
# This prevents 409 conflicts on apply and ensures destroy cleans everything.
try_import() {
  tg import "$1" "$2" 2>/dev/null \
    && echo "  reconciled: $1" || true
}
echo "==> Reconciling pre-existing GCP resources..."
try_import google_storage_bucket.artifacts    "thesis-test-artifacts-${PROJECT}"
try_import google_compute_network.main        "projects/${PROJECT}/global/networks/thesis-vpc"
try_import google_compute_subnetwork.main     "projects/${PROJECT}/regions/${REGION}/subnetworks/thesis-subnet"
try_import google_container_cluster.main      "projects/${PROJECT}/locations/${ZONE}/clusters/thesis-cluster"
try_import google_container_node_pool.main    "projects/${PROJECT}/locations/${ZONE}/clusters/thesis-cluster/nodePools/thesis-nodes"

echo "==> Provisioning GCP infrastructure..."
tg apply -auto-approve -input=false

CLUSTER=$(tg output -raw gke_cluster_name)
BUCKET=$(tg output -raw artifacts_bucket)

echo "==> Configuring kubectl for GKE cluster $CLUSTER..."
gcloud container clusters get-credentials "$CLUSTER" \
  --zone "$ZONE" --project "$PROJECT"

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

DATETIME=$(date +%Y-%m-%d_%H-%M-%S)

for i in $(seq 1 "$ITERATIONS"); do
  echo "==> Running test iteration $i/$ITERATIONS..."
  if BUILD_ID=$(gcloud builds submit "$REPO_ROOT" \
    --config="$REPO_ROOT/pipelines/gcp/cloudbuild.yaml" \
    --project="$PROJECT" \
    --region="$REGION" \
    --substitutions="_BASE_URL=$BASE_URL,_ITERATION=$i" \
    --format="value(id)" \
    --suppress-logs); then
    STATUS="SUCCESS"
  else
    STATUS="FAILURE"
  fi
  echo "  Build ID: $BUILD_ID"
  echo "  Status: $STATUS"

  [ "$STATUS" != "SUCCESS" ] && echo "WARNING: iteration $i finished with status $STATUS"

  echo "==> Downloading metrics for iteration $i..."
  METRICS_DIR="$REPO_ROOT/metrics/gcp/$DATETIME/iteration-$i"
  mkdir -p "$METRICS_DIR"
  GCS_CONTENTS=$(gsutil ls -r "gs://$BUCKET/runs/$BUILD_ID/" 2>/dev/null || true)
  JSON_URLS=$(echo "$GCS_CONTENTS" | grep '\.json$' || true)
  if [ -n "$JSON_URLS" ]; then
    echo "$JSON_URLS" | gsutil -m -o "GSUtil:parallel_process_count=1" cp -I "$METRICS_DIR/"
    echo "  Saved to $METRICS_DIR ($(find "$METRICS_DIR" -name '*.json' | wc -l | tr -d ' ') file(s))"
  else
    echo "  WARNING: no JSON metrics found at gs://$BUCKET/runs/$BUILD_ID/"
    echo "  GCS contents: $GCS_CONTENTS"
  fi
done

echo "==> Generating summary..."
node "$REPO_ROOT/scripts/summarize.js" "$REPO_ROOT/metrics/gcp/$DATETIME"

echo "==> All $ITERATIONS iteration(s) complete."

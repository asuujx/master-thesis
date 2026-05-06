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

# Cluster metadata — read from terragrunt/root.hcl so metadata cannot drift from deployed config.
K8S_VERSION=$(awk -F'"' '/k8s_version/{print $2}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_COUNT=$(awk '/node_count/{print $3; exit}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_TYPE=$(awk -F'"' '/node_machine_type/{print $2}' "$TF_DIR/terragrunt.hcl")
LB_TYPE="gcp-network-lb"
RUNNER_TYPE="cloud-build"

# Convert ISO 8601 timestamp to Unix epoch seconds. Returns 0 on empty/invalid input.
iso_to_epoch() {
  [ -z "${1:-}" ] || [ "$1" = "None" ] && { echo 0; return; }
  python3 -c "import sys,datetime; s=sys.argv[1].strip().replace('Z','+00:00'); print(int(datetime.datetime.fromisoformat(s).timestamp()) if s else 0)" "$1" 2>/dev/null || echo 0
}

cleanup() {
  # Kubernetes creates GCP forwarding rules, target pools, health checks, and firewall rules
  # outside Terraform state. They must be drained before tg destroy can delete the VPC.
  echo "==> Removing Kubernetes LoadBalancer service..."
  kubectl delete service frontend-external --ignore-not-found=true --timeout=120s 2>/dev/null || true

  echo "==> Waiting for GCP forwarding rules to drain (polling every 10s)..."
  # Filter to GKE-managed names so unrelated workloads in the project don't block the loop.
  # Legacy L4 NLB: a<hex>. Newer GKE LBs: k8s-* / k8s2-*.
  for i in $(seq 1 30); do
    FWD_RULES=$(gcloud compute forwarding-rules list \
      --project="$PROJECT" \
      --filter="name~'^a[a-f0-9]+$' OR name~'^k8s'" \
      --format="value(name)" 2>/dev/null || true)
    [ -z "$FWD_RULES" ] && echo "  Forwarding rules drained." && break
    echo "  still draining (attempt $i/30)..."
    sleep 10
  done

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
PROVISION_START=$SECONDS
tg apply -auto-approve -input=false
PROVISION_DURATION=$((SECONDS - PROVISION_START))

CLUSTER=$(tg output -raw gke_cluster_name)
BUCKET=$(tg output -raw artifacts_bucket)

echo "==> Configuring kubectl for GKE cluster $CLUSTER..."
gcloud container clusters get-credentials "$CLUSTER" \
  --zone "$ZONE" --project "$PROJECT"

echo "==> Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> Deploying app..."
DEPLOY_START=$SECONDS
kubectl apply -f "$REPO_ROOT/app/manifests/kubernetes-manifests.yaml"
# LB_START captures Service object creation, when GKE begins LB provisioning. This runs
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
  METRICS_DIR="$REPO_ROOT/metrics/gcp/$DATETIME/iteration-$i"
  mkdir -p "$METRICS_DIR"

  echo "==> Capturing Kubernetes metrics before iteration $i..."
  bash "$REPO_ROOT/scripts/metrics/capture-kube-metrics.sh" "before" "$METRICS_DIR/kube_metrics_before.json" \
    || echo "  WARNING: kube metrics capture failed"

  echo "==> Running test iteration $i/$ITERATIONS..."
  SUBMIT_TS=$(date +%s)
  BUILD_ID=$(gcloud builds submit "$REPO_ROOT" \
    --config="$REPO_ROOT/pipelines/gcp/cloudbuild.yaml" \
    --project="$PROJECT" \
    --region="$REGION" \
    --substitutions="_BASE_URL=$BASE_URL,_ITERATION=$i,_NODE_TYPE=$NODE_TYPE,_NODE_COUNT=$NODE_COUNT,_K8S_VERSION=$K8S_VERSION,_CLUSTER_REGION=$REGION,_LB_TYPE=$LB_TYPE,_RUNNER_TYPE=$RUNNER_TYPE" \
    --format="value(id)" \
    --async)
  echo "  Build ID: $BUILD_ID"

  STATUS="WORKING"
  while [[ "$STATUS" == "WORKING" || "$STATUS" == "QUEUED" ]]; do
    sleep 30
    STATUS=$(gcloud builds describe "$BUILD_ID" \
      --project="$PROJECT" --region="$REGION" \
      --format="value(status)")
    echo "  Status: $STATUS"
  done

  [ "$STATUS" != "SUCCESS" ] && echo "WARNING: iteration $i finished with status $STATUS"

  # Capture runner queue/execution time from Cloud Build API. createTime is when the build was
  # queued; startTime is when a worker picked it up; finishTime is completion. Pipeline-side
  # install/test timings are downloaded as part of runner_timings.json.
  RUNNER_TIMES=$(gcloud builds describe "$BUILD_ID" --project="$PROJECT" --region="$REGION" \
    --format="value(createTime,startTime,finishTime)" 2>/dev/null || echo "")
  RUNNER_CREATE_ISO=$(echo "$RUNNER_TIMES" | awk -F'\t' '{print $1}')
  RUNNER_START_ISO=$(echo "$RUNNER_TIMES" | awk -F'\t' '{print $2}')
  RUNNER_END_ISO=$(echo "$RUNNER_TIMES" | awk -F'\t' '{print $3}')
  RUNNER_CREATE=$(iso_to_epoch "$RUNNER_CREATE_ISO")
  RUNNER_START=$(iso_to_epoch "$RUNNER_START_ISO")
  RUNNER_END=$(iso_to_epoch "$RUNNER_END_ISO")
  if [ "$RUNNER_START" -gt 0 ] && [ "$RUNNER_END" -gt 0 ] && [ "$RUNNER_CREATE" -gt 0 ]; then
    RUNNER_QUEUE_SECONDS=$((RUNNER_START - RUNNER_CREATE))
    RUNNER_EXEC_SECONDS=$((RUNNER_END - RUNNER_START))
  else
    RUNNER_QUEUE_SECONDS=-1
    RUNNER_EXEC_SECONDS=-1
  fi
  cat > "$METRICS_DIR/provider_timings.json" << TIMINGS_EOF
{
  "submitEpoch": $SUBMIT_TS,
  "runnerCreateIso": "$RUNNER_CREATE_ISO",
  "runnerStartIso": "$RUNNER_START_ISO",
  "runnerEndIso": "$RUNNER_END_ISO",
  "runnerQueueSeconds": $RUNNER_QUEUE_SECONDS,
  "runnerExecutionSeconds": $RUNNER_EXEC_SECONDS
}
TIMINGS_EOF

  echo "==> Downloading metrics for iteration $i..."
  GCS_CONTENTS=$(gsutil ls -r "gs://$BUCKET/runs/$BUILD_ID/" 2>/dev/null || true)
  JSON_URLS=$(echo "$GCS_CONTENTS" | grep '\.json$' || true)
  if [ -n "$JSON_URLS" ]; then
    echo "$JSON_URLS" | gsutil -m -o "GSUtil:parallel_process_count=1" cp -I "$METRICS_DIR/"
    echo "  Saved to $METRICS_DIR ($(find "$METRICS_DIR" -name '*.json' | wc -l | tr -d ' ') file(s))"
  else
    echo "  WARNING: no JSON metrics found at gs://$BUCKET/runs/$BUILD_ID/"
    echo "  GCS contents: $GCS_CONTENTS"
  fi

  echo "==> Capturing Kubernetes metrics after iteration $i..."
  bash "$REPO_ROOT/scripts/metrics/capture-kube-metrics.sh" "after" "$METRICS_DIR/kube_metrics_after.json" \
    || echo "  WARNING: kube metrics capture failed"
done

SUITE_DURATION=$((SECONDS - SUITE_START_S))
SUITE_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "==> Generating summary..."
node "$REPO_ROOT/scripts/metrics/summarize.js" "$REPO_ROOT/metrics/gcp/$DATETIME"

echo "==> Writing run metadata..."
cat > "$REPO_ROOT/metrics/gcp/$DATETIME/run_metadata.json" << METADATA_EOF
{
  "cloud": "gcp",
  "environment": "gke",
  "nodeType": "$NODE_TYPE",
  "nodeCount": $NODE_COUNT,
  "k8sVersion": "$K8S_VERSION",
  "clusterRegion": "$REGION",
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

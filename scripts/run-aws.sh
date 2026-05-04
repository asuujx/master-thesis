#!/usr/bin/env bash
# Usage: ITERATIONS=5 ./scripts/run-aws.sh
# Required env: TF_VAR_github_token
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
TF_DIR="$REPO_ROOT/infrastructure/aws"
ITERATIONS="${ITERATIONS:-1}"

tg() { (cd "$TF_DIR" && terragrunt "$@"); }

# Cluster metadata — mirrors infrastructure/root.hcl and infrastructure/aws/eks.tf
K8S_VERSION=$(awk -F'"' '/k8s_version/{print $2}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_COUNT=$(awk '/node_count/{print $3}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_TYPE="t3.medium"
LB_TYPE="aws-classic-lb"
RUNNER_TYPE="codebuild"

cleanup() {
  echo "==> Removing Kubernetes LoadBalancer service (releases ELB before VPC destroy)..."
  # ELBs created by k8s services are outside Terraform state. If they still exist when
  # terraform destroy runs, the VPC subnet deletion fails with a dependency error.
  kubectl delete service frontend-external --ignore-not-found=true 2>/dev/null || true
  echo "  Waiting 60s for ELB to be fully deprovisioned..."
  sleep 60

  echo "==> Detaching persistent resources from state (IAM roles, S3, and CodeBuild project survive between runs)..."
  tg state rm aws_s3_bucket.artifacts          2>/dev/null || true
  tg state rm aws_iam_role.codebuild           2>/dev/null || true
  tg state rm aws_iam_role.eks_cluster         2>/dev/null || true
  tg state rm aws_iam_role.eks_nodes           2>/dev/null || true
  tg state rm aws_codebuild_project.playwright 2>/dev/null || true

  echo "==> Destroying ephemeral AWS infrastructure..."
  tg destroy -auto-approve
}
trap cleanup EXIT

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Provisioning AWS infrastructure..."
tg init -input=false

echo "==> Reconciling pre-existing AWS resources..."
try_import() {
  local resource="$1" id="$2"
  if tg state show "$resource" >/dev/null 2>&1; then
    echo "  already in state: $resource"
    return 0
  fi
  tg import -input=false "$resource" "$id" \
    && echo "  imported: $resource" \
    || echo "  not found in AWS, will be created: $resource"
}
try_import aws_s3_bucket.artifacts          "thesis-test-artifacts-$ACCOUNT_ID"
try_import aws_iam_role.codebuild           "thesis-codebuild-role"
try_import aws_iam_role.eks_cluster         "thesis-eks-cluster-role"
try_import aws_iam_role.eks_nodes           "thesis-eks-node-role"
try_import aws_codebuild_project.playwright "thesis-playwright-tests"

PROVISION_START=$SECONDS
tg apply -auto-approve -input=false
PROVISION_DURATION=$((SECONDS - PROVISION_START))

REGION=$(tg output -raw aws_region)
CLUSTER=$(tg output -raw eks_cluster_name)
CODEBUILD_PROJECT=$(tg output -raw codebuild_project_name)
BUCKET=$(tg output -raw artifacts_bucket)

echo "==> Configuring kubectl for EKS cluster $CLUSTER..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo "==> Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> Installing metrics-server (not bundled with EKS)..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

echo "==> Deploying app..."
DEPLOY_START=$SECONDS
kubectl apply -f "$REPO_ROOT/app/manifests/kubernetes-manifests.yaml"

echo "==> Waiting for frontend deployment..."
kubectl rollout status deployment/frontend --timeout=300s
DEPLOY_DURATION=$((SECONDS - DEPLOY_START))

echo "==> Waiting for LoadBalancer hostname (this can take 2-5 minutes on EKS)..."
LB_START=$SECONDS
HOSTNAME=""
for i in $(seq 1 30); do
  HOSTNAME=$(kubectl get service frontend-external \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$HOSTNAME" ] && break
  echo "  attempt $i/30, retrying in 20s..."
  sleep 20
done
[ -z "$HOSTNAME" ] && { echo "ERROR: LoadBalancer hostname not assigned after 10 minutes"; exit 1; }
LB_DURATION=$((SECONDS - LB_START))
BASE_URL="http://$HOSTNAME"
echo "==> App URL: $BASE_URL"

DATETIME=$(date +%Y-%m-%d_%H-%M-%S)
SUITE_START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SUITE_START_S=$SECONDS

for i in $(seq 1 "$ITERATIONS"); do
  METRICS_DIR="$REPO_ROOT/metrics/aws/$DATETIME/iteration-$i"
  mkdir -p "$METRICS_DIR"

  echo "==> Capturing Kubernetes metrics before iteration $i..."
  bash "$REPO_ROOT/scripts/metrics/capture-kube-metrics.sh" "before" "$METRICS_DIR/kube_metrics_before.json" \
    || echo "  WARNING: kube metrics capture failed"

  echo "==> Running test iteration $i/$ITERATIONS..."
  BUILD_ID=$(aws codebuild start-build \
    --project-name "$CODEBUILD_PROJECT" \
    --environment-variables-override \
      "name=BASE_URL,value=$BASE_URL,type=PLAINTEXT" \
      "name=ITERATION,value=$i,type=PLAINTEXT" \
      "name=NODE_TYPE,value=$NODE_TYPE,type=PLAINTEXT" \
      "name=NODE_COUNT,value=$NODE_COUNT,type=PLAINTEXT" \
      "name=K8S_VERSION,value=$K8S_VERSION,type=PLAINTEXT" \
      "name=CLUSTER_REGION,value=$REGION,type=PLAINTEXT" \
      "name=LB_TYPE,value=$LB_TYPE,type=PLAINTEXT" \
      "name=RUNNER_TYPE,value=$RUNNER_TYPE,type=PLAINTEXT" \
    --query 'build.id' --output text)
  echo "  Build ID: $BUILD_ID"

  STATUS="IN_PROGRESS"
  while [ "$STATUS" = "IN_PROGRESS" ]; do
    sleep 30
    STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
      --query 'builds[0].buildStatus' --output text)
    echo "  Status: $STATUS"
  done

  [ "$STATUS" != "SUCCEEDED" ] && echo "WARNING: iteration $i finished with status $STATUS"

  echo "==> Downloading metrics for iteration $i..."
  if aws s3 sync "s3://$BUCKET/runs/$BUILD_ID/results/" "$METRICS_DIR/" --region "$REGION"; then
    echo "  Saved to $METRICS_DIR ($(find "$METRICS_DIR" -name '*.json' | wc -l | tr -d ' ') file(s))"
  else
    echo "  WARNING: metrics download failed — artifacts may be at s3://$BUCKET/runs/$BUILD_ID/results/"
  fi

  echo "==> Capturing Kubernetes metrics after iteration $i..."
  bash "$REPO_ROOT/scripts/metrics/capture-kube-metrics.sh" "after" "$METRICS_DIR/kube_metrics_after.json" \
    || echo "  WARNING: kube metrics capture failed"
done

SUITE_DURATION=$((SECONDS - SUITE_START_S))
SUITE_END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "==> Generating summary..."
node "$REPO_ROOT/scripts/metrics/summarize.js" "$REPO_ROOT/metrics/aws/$DATETIME"

echo "==> Writing run metadata..."
cat > "$REPO_ROOT/metrics/aws/$DATETIME/run_metadata.json" << METADATA_EOF
{
  "cloud": "aws",
  "environment": "eks",
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

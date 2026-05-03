#!/usr/bin/env bash
# Usage: ITERATIONS=5 ./scripts/run-aws.sh
# Required env: TF_VAR_github_token
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/infrastructure/aws"
ITERATIONS="${ITERATIONS:-1}"

tg() { (cd "$TF_DIR" && terragrunt "$@"); }

cleanup() {
  echo "==> Removing Kubernetes LoadBalancer service (releases ELB before VPC destroy)..."
  # ELBs created by k8s services are outside Terraform state. If they still exist when
  # terraform destroy runs, the VPC subnet deletion fails with a dependency error.
  kubectl delete service frontend-external --ignore-not-found=true 2>/dev/null || true
  echo "  Waiting 60s for ELB to be fully deprovisioned..."
  sleep 60

  echo "==> Destroying AWS infrastructure..."
  tg destroy -auto-approve || true
}
trap cleanup EXIT

echo "==> Provisioning AWS infrastructure..."
tg init -input=false
tg apply -auto-approve -input=false

REGION=$(tg output -raw aws_region)
CLUSTER=$(tg output -raw eks_cluster_name)
CODEBUILD_PROJECT=$(tg output -raw codebuild_project_name)
BUCKET=$(tg output -raw artifacts_bucket)

echo "==> Configuring kubectl for EKS cluster $CLUSTER..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo "==> Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> Deploying app..."
kubectl apply -f "$REPO_ROOT/app/manifests/kubernetes-manifests.yaml"

echo "==> Waiting for frontend deployment..."
kubectl rollout status deployment/frontend --timeout=300s

echo "==> Waiting for LoadBalancer hostname (this can take 2-5 minutes on EKS)..."
HOSTNAME=""
for i in $(seq 1 30); do
  HOSTNAME=$(kubectl get service frontend-external \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$HOSTNAME" ] && break
  echo "  attempt $i/30, retrying in 20s..."
  sleep 20
done
[ -z "$HOSTNAME" ] && { echo "ERROR: LoadBalancer hostname not assigned after 10 minutes"; exit 1; }
BASE_URL="http://$HOSTNAME"
echo "==> App URL: $BASE_URL"

DATETIME=$(date +%Y-%m-%d_%H-%M-%S)

for i in $(seq 1 "$ITERATIONS"); do
  echo "==> Running test iteration $i/$ITERATIONS..."
  BUILD_ID=$(aws codebuild start-build \
    --project-name "$CODEBUILD_PROJECT" \
    --environment-variables-override \
      "name=BASE_URL,value=$BASE_URL,type=PLAINTEXT" \
      "name=ITERATION,value=$i,type=PLAINTEXT" \
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
  METRICS_DIR="$REPO_ROOT/metrics/aws/$DATETIME/iteration-$i"
  mkdir -p "$METRICS_DIR"
  if aws s3 sync "s3://$BUCKET/runs/$BUILD_ID/results/" "$METRICS_DIR/" --region "$REGION"; then
    echo "  Saved to $METRICS_DIR ($(find "$METRICS_DIR" -name '*.json' | wc -l | tr -d ' ') file(s))"
  else
    echo "  WARNING: metrics download failed — artifacts may be at s3://$BUCKET/runs/$BUILD_ID/results/"
  fi
done

echo "==> All $ITERATIONS iteration(s) complete."

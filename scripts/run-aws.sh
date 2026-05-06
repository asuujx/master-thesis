#!/usr/bin/env bash
# Usage: ITERATIONS=5 ./scripts/run-aws.sh
# Required env: TF_VAR_github_token
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && set -a && source "$REPO_ROOT/.env" && set +a
TF_DIR="$REPO_ROOT/infrastructure/aws"
ITERATIONS="${ITERATIONS:-1}"

tg() { (cd "$TF_DIR" && terragrunt "$@"); }

# Cluster metadata — read from terragrunt/root.hcl so metadata cannot drift from deployed config.
K8S_VERSION=$(awk -F'"' '/k8s_version/{print $2}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_COUNT=$(awk '/node_count/{print $3; exit}' "$REPO_ROOT/infrastructure/root.hcl")
NODE_TYPE=$(awk -F'"' '/node_instance_type/{print $2}' "$TF_DIR/terragrunt.hcl")
LB_TYPE="aws-classic-lb"
RUNNER_TYPE="codebuild"

# Convert ISO 8601 timestamp to Unix epoch seconds. Returns 0 on empty/invalid input.
iso_to_epoch() {
  [ -z "${1:-}" ] || [ "$1" = "None" ] && { echo 0; return; }
  python3 -c "import sys,datetime; s=sys.argv[1].strip().replace('Z','+00:00'); print(int(datetime.datetime.fromisoformat(s).timestamp()) if s else 0)" "$1" 2>/dev/null || echo 0
}

cleanup() {
  VPC_ID=$(tg output -raw vpc_id 2>/dev/null || true)

  echo "==> Removing Kubernetes LoadBalancer service..."
  kubectl delete service frontend-external --ignore-not-found=true 2>/dev/null || true

  # Poll until the ELB is fully gone rather than sleeping a fixed amount.
  # Kubernetes creates the ELB and its security group outside Terraform state;
  # both must be gone before terraform destroy can delete the VPC.
  if [ -n "$VPC_ID" ]; then
    echo "==> Waiting for ELB to deprovision (polling every 10s)..."
    for i in $(seq 1 36); do
      ELB_NAMES=$(aws elb describe-load-balancers \
        --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" \
        --output text 2>/dev/null || true)
      [ -z "$ELB_NAMES" ] && echo "  ELB deprovisioned." && break
      echo "  ELB still exists (attempt $i/36), force-deleting..."
      for name in $ELB_NAMES; do
        aws elb delete-load-balancer --load-balancer-name "$name" 2>/dev/null || true
      done
      sleep 10
    done

    echo "==> Cleaning up Kubernetes-managed security groups..."
    SG_IDS=$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
      --output text 2>/dev/null || true)
    for sg in $SG_IDS; do
      aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
      echo "  Deleted SG: $sg"
    done

    echo "==> Cleaning up orphaned ENIs..."
    ENI_IDS=$(aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'NetworkInterfaces[*].NetworkInterfaceId' \
      --output text 2>/dev/null || true)
    for eni in $ENI_IDS; do
      ATTACH_ID=$(aws ec2 describe-network-interfaces \
        --network-interface-ids "$eni" \
        --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
        --output text 2>/dev/null || true)
      if [ -n "$ATTACH_ID" ] && [ "$ATTACH_ID" != "None" ]; then
        aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force 2>/dev/null || true
        sleep 5
      fi
      aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
      echo "  Deleted ENI: $eni"
    done
  fi

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
# LB_START captures Service object creation, when EKS begins ELB provisioning. This runs
# in parallel with the deployment, so DEPLOY_DURATION and LB_DURATION overlap by design.
LB_START=$SECONDS

echo "==> Waiting for frontend deployment..."
kubectl rollout status deployment/frontend --timeout=300s
DEPLOY_DURATION=$((SECONDS - DEPLOY_START))

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
LB_DURATION=$((SECONDS - LB_START))
BASE_URL="http://$HOSTNAME"
echo "==> App URL: $BASE_URL"

echo "==> Waiting 30s for all pods to reach steady state..."
sleep 30

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
  SUBMIT_TS=$(date +%s)
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

  # Capture runner queue/execution time from CodeBuild API. CodeBuild does not expose a "submit"
  # timestamp, so we recorded it client-side in SUBMIT_TS before start-build. queue = start - submit;
  # execution = end - start. Pipeline-side install/test timings are downloaded in runner_timings.json.
  RUNNER_START_ISO=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
    --query 'builds[0].startTime' --output text 2>/dev/null || echo "")
  RUNNER_END_ISO=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
    --query 'builds[0].endTime' --output text 2>/dev/null || echo "")
  RUNNER_START=$(iso_to_epoch "$RUNNER_START_ISO")
  RUNNER_END=$(iso_to_epoch "$RUNNER_END_ISO")
  if [ "$RUNNER_START" -gt 0 ] && [ "$RUNNER_END" -gt 0 ]; then
    RUNNER_QUEUE_SECONDS=$((RUNNER_START - SUBMIT_TS))
    RUNNER_EXEC_SECONDS=$((RUNNER_END - RUNNER_START))
  else
    RUNNER_QUEUE_SECONDS=-1
    RUNNER_EXEC_SECONDS=-1
  fi
  cat > "$METRICS_DIR/provider_timings.json" << TIMINGS_EOF
{
  "submitEpoch": $SUBMIT_TS,
  "runnerStartIso": "$RUNNER_START_ISO",
  "runnerEndIso": "$RUNNER_END_ISO",
  "runnerQueueSeconds": $RUNNER_QUEUE_SECONDS,
  "runnerExecutionSeconds": $RUNNER_EXEC_SECONDS
}
TIMINGS_EOF

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

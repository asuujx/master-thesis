# Master Thesis — Multi-Cloud Playwright Performance Testing

Automated Playwright e2e test suite run against Google Online Boutique deployed on Kubernetes across AWS (EKS), GCP (GKE), and locally via Docker Compose. Each run collects per-test performance metrics (FCP, LCP, TTFB, load time) stored in `results/<cloud>_<env>.json`.

---

## Local

### Prerequisites
- Docker Desktop
- Node.js 20+

### Run tests locally

```bash
npm ci
npx playwright install chromium --with-deps
npm run e2e
```

Results saved to `results/local_local.json`.

---

## AWS (EKS + CodeBuild)

### Prerequisites
- AWS CLI configured (`aws configure`)
- kubectl
- Terraform >= 1.5

### 1. Provision infrastructure

```bash
cd infrastructure/aws
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set github_repo

export TF_VAR_github_token="github_pat_..."
terraform init
terraform apply
```

### 2. Connect kubectl to EKS

```bash
aws eks update-kubeconfig --region eu-central-1 --name thesis-cluster
```

### 3. Deploy the app

```bash
kubectl apply -f app/manifests/kubernetes-manifests.yaml

# wait for LoadBalancer hostname (~2 min)
kubectl get service frontend-external --watch
```

### 4. Run tests

```bash
aws codebuild start-build \
  --project-name thesis-playwright-tests \
  --environment-variables-override \
    name=BASE_URL,value=http://<elb-hostname>,type=PLAINTEXT \
    name=ITERATION,value=1,type=PLAINTEXT
```

### 5. Tear down

```bash
kubectl delete -f app/manifests/kubernetes-manifests.yaml
cd infrastructure/aws && terraform destroy
```

---

## GCP (GKE + Cloud Build)

### Prerequisites
- gcloud CLI (`gcloud auth login && gcloud auth application-default login`)
- gke-gcloud-auth-plugin (`gcloud components install gke-gcloud-auth-plugin`)
- kubectl
- Terraform >= 1.5

### 1. Provision infrastructure

```bash
cd infrastructure/gcp
terraform init
terraform apply
# uses terraform.tfvars — project_id, github_owner, github_repo_name already set
```

### 2. Connect kubectl to GKE

```bash
gcloud container clusters get-credentials thesis-cluster \
  --zone europe-west3-c \
  --project thesis-playwright-gcp
```

### 3. Deploy the app

```bash
kubectl apply -f app/manifests/kubernetes-manifests.yaml

# wait for LoadBalancer IP (~2 min)
kubectl get service frontend-external --watch
```

### 4. Run tests

```bash
# run from repo root
gcloud builds submit . \
  --config=pipelines/gcp/cloudbuild.yaml \
  --region=europe-west3 \
  --substitutions "_BASE_URL=http://<frontend-ip>,_ITERATION=1"
```

### 5. Tear down

```bash
kubectl delete -f app/manifests/kubernetes-manifests.yaml
cd infrastructure/gcp && terraform destroy
```

---

## Infrastructure summary

| | AWS | GCP |
|---|---|---|
| Kubernetes | EKS (eu-central-1) | GKE zonal (europe-west3-c) |
| Nodes | 2× t3.medium | 2× e2-standard-2 |
| CI runner | CodeBuild | Cloud Build |
| Artifacts | S3 | GCS |
| Pipeline file | `pipelines/aws/buildspec.yml` | `pipelines/gcp/cloudbuild.yaml` |

## Results

Test results accumulate in `results/<cloud>_<env>.json` on each run:
- `results/local_local.json`
- `results/aws_eks.json`
- `results/gcp_gke.json`

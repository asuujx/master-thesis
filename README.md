# Master Thesis — Multi-Cloud Playwright Performance Testing

Automated Playwright e2e test suite run against Google Online Boutique deployed on Kubernetes across AWS (EKS), GCP (GKE), Azure (AKS), and locally via Docker Compose. Each run collects per-iteration metrics: Playwright web vitals, Kubernetes resource usage, network RTT, and CI runner timings — stored under `metrics/<cloud>/<datetime>/`.

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

---

## Cloud runs (AWS / GCP / Azure)

Each cloud has a self-contained script that provisions infrastructure, deploys the app, runs N test iterations, collects metrics, and tears everything down.

### Prerequisites (all clouds)

- Node.js 20+
- [Terragrunt](https://terragrunt.gruntwork.io/) (`brew install terragrunt`)
- kubectl

### AWS (EKS + CodeBuild)

Additional prerequisites: AWS CLI configured (`aws configure`)

```bash
# First run: set GitHub token so CodeBuild can pull the repo
export TF_VAR_github_token="github_pat_..."

ITERATIONS=30 ./scripts/run-aws.sh
```

### GCP (GKE + Cloud Build)

Additional prerequisites:

- `gcloud auth login && gcloud auth application-default login`
- `gcloud components install gke-gcloud-auth-plugin`

```bash
ITERATIONS=30 ./scripts/run-gcp.sh
```

### Azure (AKS + Azure Pipelines)

Additional prerequisites:

- `az login`
- `az extension add --name azure-devops`

```bash
# First run only: GitHub PAT to create the Azure Pipelines pipeline
# Required scopes: repo, admin:repo_hook, user
export AZURE_DEVOPS_EXT_GITHUB_PAT="github_pat_..."

ITERATIONS=30 ./scripts/run-azure.sh
```

Azure DevOps org: `balon-thesis`, project: `thesis`.

---

## Infrastructure summary

| | AWS | GCP | Azure |
| --- | --- | --- | --- |
| Kubernetes | EKS 1.35 (eu-central-1) | GKE 1.35 zonal (europe-west3-c) | AKS 1.35 (germanywestcentral) |
| Nodes | 2× m5.large (2 vCPU, 8 GB) | 2× n2-standard-2 (2 vCPU, 8 GB) | 2× Standard_D2s_v4 (2 vCPU, 8 GB) |
| CI runner | CodeBuild (eu-central-1) | Cloud Build (europe-west3) | Azure Pipelines (West Europe†) |
| Artifacts | S3 | GCS | Azure Blob Storage |
| Pipeline file | `pipelines/aws/buildspec.yml` | `pipelines/gcp/cloudbuild.yaml` | `pipelines/azure/azure-pipelines.yml` |

† Microsoft-hosted agents do not support region selection — runner may be in West Europe (Amsterdam) rather than germanywestcentral. See thesis limitations.

---

## Metrics structure

Each cloud run writes to `metrics/<cloud>/<datetime>/`:

```text
metrics/aws/2026-05-09_21-32-06/
  run_metadata.json           # cloud, node type, iteration count, provisioning/deploy durations
  iteration-1/
    aws_eks.json              # Playwright web vitals (FCP, LCP, TTFB, load time) per test
    network_rtt.json          # 5 curl probes from CI runner to LoadBalancer
    kube_metrics_before.json  # kubectl top nodes/pods snapshot before the test run
    kube_metrics_after.json   # kubectl top nodes/pods snapshot after the test run
    provider_timings.json     # CI runner queue time and execution time
    runner_timings.json       # pipeline-side install and test phase durations
  iteration-2/
    ...
  summary.json                # aggregated stats across all iterations
```

Scripts that produce these files:

- `scripts/run-aws.sh` / `scripts/run-gcp.sh` / `scripts/run-azure.sh` — orchestrate the full run
- `scripts/metrics/capture-kube-metrics.sh` — kubectl top snapshots
- `scripts/metrics/measure-rtt.sh` — network RTT probes
- `scripts/metrics/summarize.js` — per-run summary aggregation

---

## Data analysis

### Aggregate raw metrics into CSVs

After one or more cloud runs exist under `metrics/<cloud>/`, flatten them into the two CSVs used for analysis:

```bash
node scripts/aggregate-results.js
```

Reads every `metrics/{aws,azure,gcp}/*/` run directory and writes:

- `metrics/results/raw.csv` — one row per (cloud × iteration × testName)
- `metrics/results/summary.csv` — one row per (cloud × testName), aggregated stats

Copy (or symlink) the ones you want to analyze into `data/` — `data/raw.csv` and `data/summary.csv` are the snapshots currently used by the notebook.

### Estimate infrastructure costs

```bash
node scripts/estimate-costs.js metrics/aws/<run> metrics/azure/<run> metrics/gcp/<run>
```

Prints a cost comparison table to stdout and writes `cost_estimate.json` into each run directory, using the on-demand pricing tables baked into the script. Consolidate the results into `data/costs.csv` for use in the notebook.

### Notebook (`data/descriptive.ipynb`)

Generates the descriptive-statistics plots used in the thesis (flakiness heatmap, runner overhead, RTT decomposition, metric boxplots, etc.) from `data/raw.csv`, `data/summary.csv`, and `data/costs.csv`, saving figures to `data/figures/`.

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install jupyterlab pandas numpy matplotlib seaborn
jupyter lab data/descriptive.ipynb
```

Run all cells top to bottom — section 1 loads and shapes the data, section 2 generates and saves each plot. The notebook resolves paths relative to the repo root (`ROOT = Path('..').resolve()`), so it must stay in `data/` and be launched from within that folder (or with its working directory set there).

# Root Terragrunt configuration — single source of truth for values shared across all three clouds.
# Each cloud's terragrunt.hcl inherits these via `include "root"`.

locals {
  k8s_version  = "1.35"
  node_count   = 2
 
  # Network CIDRs kept identical across clouds for thesis comparability.
  node_cidr    = "10.0.0.0/16"
  pod_cidr     = "10.1.0.0/16"
  service_cidr = "10.2.0.0/20"
}

inputs = {
  k8s_version  = local.k8s_version
  node_count   = local.node_count
  node_cidr    = local.node_cidr
  pod_cidr     = local.pod_cidr
  service_cidr = local.service_cidr
}

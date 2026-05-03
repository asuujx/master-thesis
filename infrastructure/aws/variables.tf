# Shared — injected from root terragrunt.hcl
variable "k8s_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
}

variable "node_count" {
  description = "Number of EKS worker nodes."
  type        = number
}

variable "node_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

# Passed from root terragrunt.hcl for consistency; EKS manages these CIDRs internally via VPC CNI.
variable "pod_cidr" {
  description = "CIDR for Kubernetes pods (unused by AWS — EKS manages this internally)."
  type        = string
}

variable "service_cidr" {
  description = "CIDR for Kubernetes services (unused by AWS — EKS manages this internally)."
  type        = string
}

# AWS-specific
variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo URL, e.g. https://github.com/yourname/master-thesis"
  type        = string
}

variable "github_token" {
  description = "GitHub fine-grained PAT (Contents: Read-only) for CodeBuild. Pass via TF_VAR_github_token."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.github_token) > 0
    error_message = "github_token must be set. Run: export TF_VAR_github_token='github_pat_...'"
  }
}

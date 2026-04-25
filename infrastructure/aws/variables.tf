variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "thesis"
}

variable "eks_node_instance_type" {
  description = "EC2 instance type for EKS worker nodes."
  type        = string
  default     = "t3.medium"
}

variable "eks_node_count" {
  description = "Number of EKS worker nodes."
  type        = number
  default     = 2
}

variable "github_repo" {
  description = "Your GitHub repo URL e.g. https://github.com/yourname/thesis-repo"
  type        = string
}

variable "github_token" {
  description = "GitHub fine-grained PAT (Contents: Read-only) for CodeBuild to pull your repo. Pass via TF_VAR_github_token env var, never in tfvars."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.github_token) > 0
    error_message = "github_token must be set. Run: export TF_VAR_github_token='github_pat_...'"
  }
}
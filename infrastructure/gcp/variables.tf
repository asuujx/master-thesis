variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "gcp_region" {
  description = "GCP region. Zone defaults to <region>-c for the GKE cluster."
  type        = string
  default     = "europe-west3"
}

variable "gke_node_machine_type" {
  description = "Machine type for GKE worker nodes (e2-medium ≈ t3.medium)."
  type        = string
  default     = "e2-standard-2"
}

variable "gke_node_count" {
  description = "Number of GKE worker nodes (total for a zonal cluster)."
  type        = number
  default     = 2
}

variable "github_owner" {
  description = "GitHub username or organisation owning the repo."
  type        = string
}

variable "github_repo_name" {
  description = "GitHub repository name (just the name, not the full URL)."
  type        = string
}

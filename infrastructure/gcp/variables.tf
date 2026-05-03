# Shared — injected from root terragrunt.hcl
variable "k8s_version" {
  description = "Kubernetes version for the GKE cluster."
  type        = string
}

variable "node_count" {
  description = "Number of GKE worker nodes (total for a zonal cluster)."
  type        = number
}

variable "node_cidr" {
  description = "Primary CIDR for the VPC subnet."
  type        = string
}

variable "pod_cidr" {
  description = "Secondary CIDR range for pods."
  type        = string
}

variable "service_cidr" {
  description = "Secondary CIDR range for services."
  type        = string
}

# GCP-specific
variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "gcp_region" {
  description = "GCP region. Zone defaults to <region>-c for the GKE cluster."
  type        = string
}

variable "node_machine_type" {
  description = "Machine type for GKE worker nodes (e2-standard-2 ≈ t3.medium: 2 vCPU, 8 GB)."
  type        = string
}

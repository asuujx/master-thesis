# Shared — injected from root terragrunt.hcl
variable "k8s_version" {
  description = "Kubernetes version for the AKS cluster."
  type        = string
}

variable "node_count" {
  description = "Number of AKS worker nodes."
  type        = number
}

variable "node_cidr" {
  description = "CIDR for the VNet node subnet."
  type        = string
}

variable "pod_cidr" {
  description = "CIDR for Kubernetes pods."
  type        = string
}

variable "service_cidr" {
  description = "CIDR for Kubernetes services."
  type        = string
}

# Azure-specific
variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "azure_region" {
  description = "Azure region for all resources."
  type        = string
}

variable "node_vm_size" {
  description = "VM size for AKS worker nodes (matched across clouds: 2 vCPU, 8 GB, Intel Cascade Lake)."
  type        = string
}

variable "storage_suffix" {
  description = "Short unique suffix for the storage account name (3-8 lowercase alphanumeric chars)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.storage_suffix))
    error_message = "storage_suffix must be 3-8 lowercase alphanumeric characters."
  }
}

variable "github_repo" {
  description = "GitHub repo URL, e.g. https://github.com/yourname/master-thesis"
  type        = string
}

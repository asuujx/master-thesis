variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "azure_region" {
  description = "Azure region for all resources."
  type        = string
  default     = "germanywestcentral"
}

variable "aks_node_vm_size" {
  description = "VM size for AKS worker nodes (Standard_DC2ads_v5: 2 vCPU x86 AMD, 8 GB ≈ e2-standard-2)."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "aks_node_count" {
  description = "Number of AKS worker nodes."
  type        = number
  default     = 2
}

variable "storage_suffix" {
  description = "Short unique suffix for the storage account name (3-8 lowercase alphanumeric chars, e.g. your initials + digits)."
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

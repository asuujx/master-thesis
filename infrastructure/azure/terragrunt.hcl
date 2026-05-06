include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  subscription_id  = "76287223-e5f3-4a6e-8897-3f42dac962d7"
  azure_region     = "germanywestcentral"
  node_vm_size     = "Standard_D2s_v5"
  storage_suffix   = "pb01"
  github_repo      = "https://github.com/asuujx/master-thesis"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  project_id         = "thesis-playwright-gcp"
  gcp_region         = "europe-west3"
  node_machine_type  = "e2-standard-2"
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

inputs = {
  aws_region             = "eu-central-1"
  node_instance_type     = "t3.medium"
  github_repo            = "https://github.com/asuujx/master-thesis"
  # github_token: pass as TF_VAR_github_token env var — never store secrets here
}

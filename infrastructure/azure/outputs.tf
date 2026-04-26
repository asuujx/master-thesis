output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "artifacts_storage_account" {
  value = azurerm_storage_account.artifacts.name
}

output "storage_account_key" {
  value     = azurerm_storage_account.artifacts.primary_access_key
  sensitive = true
}

output "kubectl_config_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}

output "deploy_app_command" {
  value = "kubectl apply -f app/manifests/kubernetes-manifests.yaml"
}

output "get_app_url_command" {
  value = "kubectl get service frontend-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}

output "run_tests_command" {
  value = "az pipelines run --name thesis-playwright-tests --parameters baseUrl=http://<frontend-ip> iteration=1"
}

output "storage_account_key_command" {
  value = "terraform output -raw storage_account_key"
}

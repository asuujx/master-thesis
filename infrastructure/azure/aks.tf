# Zonal cluster in germanywestcentral-1 zone, 2×Standard_D2s_v3 — matches GCP e2-standard-2 (2 vCPU, 8 GB).
resource "azurerm_kubernetes_cluster" "main" {
  name                = "thesis-cluster"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "thesis"
  kubernetes_version  = "1.32"

  default_node_pool {
    name                        = "default"
    node_count                  = var.aks_node_count
    vm_size                     = var.aks_node_vm_size
    vnet_subnet_id              = azurerm_subnet.nodes.id
    temporary_name_for_rotation = "tmppool"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "kubenet"
    pod_cidr       = "10.1.0.0/16"
    service_cidr   = "10.2.0.0/20"
    dns_service_ip = "10.2.0.10"
  }
}

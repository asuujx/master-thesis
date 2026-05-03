resource "azurerm_virtual_network" "main" {
  name                = "thesis-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/8"]
}

resource "azurerm_subnet" "nodes" {
  name                 = "thesis-nodes-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.node_cidr]
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "thesis-cluster"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "thesis"
  kubernetes_version  = var.k8s_version

  default_node_pool {
    name                        = "default"
    node_count                  = var.node_count
    vm_size                     = var.node_vm_size
    vnet_subnet_id              = azurerm_subnet.nodes.id
    temporary_name_for_rotation = "tmppool"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "kubenet"
    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = cidrhost(var.service_cidr, 10)
  }
}

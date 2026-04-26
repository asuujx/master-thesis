# Zonal cluster (location = zone) keeps node_count as total nodes, matching AWS's 2-node setup.
# To change zone, override gcp_region — zone defaults to <region>-c.
resource "google_container_cluster" "main" {
  name             = "thesis-cluster"
  location         = "${var.gcp_region}-c"
  min_master_version = "1.32"

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.main.name
  subnetwork = google_compute_subnetwork.main.name

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  depends_on = [google_project_service.container]
}

resource "google_container_node_pool" "main" {
  name       = "thesis-nodes"
  location   = "${var.gcp_region}-c"
  cluster    = google_container_cluster.main.name
  node_count = var.gke_node_count
  version    = "1.32"

  node_config {
    machine_type = var.gke_node_machine_type
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}

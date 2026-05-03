resource "google_compute_network" "main" {
  name                    = "thesis-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "thesis-subnet"
  ip_cidr_range = var.node_cidr
  region        = var.gcp_region
  network       = google_compute_network.main.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pod_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.service_cidr
  }
}

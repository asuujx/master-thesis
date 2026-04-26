output "gke_cluster_name" {
  value = google_container_cluster.main.name
}

output "artifacts_bucket" {
  value = google_storage_bucket.artifacts.name
}

output "kubectl_config_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --zone ${var.gcp_region}-c --project ${var.project_id}"
}

output "deploy_app_command" {
  value = "kubectl apply -f app/manifests/kubernetes-manifests.yaml"
}

output "get_app_url_command" {
  value = "kubectl get service frontend-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}

output "run_tests_command" {
  value = "gcloud builds submit . --config=pipelines/gcp/cloudbuild.yaml --region=${var.gcp_region} --substitutions=_BASE_URL=<frontend-ip>,_ITERATION=1"
}

data "google_project" "current" {}

# Cloud Build SA is created lazily after API activation — wait for it.
resource "time_sleep" "wait_cloudbuild_sa" {
  create_duration = "30s"
  depends_on      = [google_project_service.cloudbuild]
}

resource "google_storage_bucket" "artifacts" {
  name          = "thesis-test-artifacts-${var.project_id}"
  location      = var.gcp_region
  force_destroy = true
}

resource "google_storage_bucket_iam_member" "cloudbuild_artifacts" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.google_project.current.number}@cloudbuild.gserviceaccount.com"

  depends_on = [time_sleep.wait_cloudbuild_sa]
}

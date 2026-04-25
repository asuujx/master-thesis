output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}

output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "codebuild_project_name" {
  value = aws_codebuild_project.playwright.name
}

output "kubectl_config_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "deploy_app_command" {
  value = "kubectl apply -f app/manifests/kubernetes-manifests.yaml"
}

output "get_app_url_command" {
  value = "kubectl get service frontend-external -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
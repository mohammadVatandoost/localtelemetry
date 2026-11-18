output "namespace" {
  description = "Namespace Argo CD was installed into."
  value       = helm_release.argocd.namespace
}

output "chart_version" {
  description = "Installed argo-cd Helm chart version."
  value       = helm_release.argocd.metadata.version
}

output "app_version" {
  description = "Argo CD version from the chart appVersion."
  value       = helm_release.argocd.metadata.app_version
}

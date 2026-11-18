locals {
  kubeconfig = var.kubeconfig != "" ? var.kubeconfig : pathexpand("~/.kube/config")
}

provider "helm" {
  kubernetes = {
    config_path    = local.kubeconfig
    config_context = var.kube_context
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.1"

  # Adopt a release that is already in the cluster when local state was removed.
  upgrade_install = true
  timeout         = 600
  wait            = true

  values = [
    file("${path.module}/values.yaml"),
  ]
}

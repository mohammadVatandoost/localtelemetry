variable "kubeconfig" {
  type        = string
  description = "kubeconfig for the Kind cluster. Empty uses ~/.kube/config."
  default     = ""
}

variable "kube_context" {
  type        = string
  description = "kubeconfig context. The Kind cluster context is kind-otel-platform."
  default     = "kind-otel-platform"
}

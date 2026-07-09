variable "kubeconfig_path" {
  type        = string
  description = "Path to the kubeconfig file for the target cluster"
}

variable "git_url" {
  type        = string
  description = "Remote Git repository URL Flux should reconcile from (for example https://github.com/your-org/your-repo.git)"
}

variable "git_branch" {
  type        = string
  description = "Git branch Flux should reconcile from"
  default     = "main"
}

variable "git_author_name" {
  type        = string
  description = "Commit author name used by Flux bootstrap"
  default     = "Flux"
}

variable "git_author_email" {
  type        = string
  description = "Commit author email used by Flux bootstrap"
  default     = "flux@example.com"
}

variable "git_http_username" {
  type        = string
  description = "HTTP username for Git authentication. For GitHub PAT auth this is commonly your GitHub username."
}

variable "git_http_password" {
  type        = string
  description = "HTTP password/token for Git authentication"
  sensitive   = true
}

variable "cluster_path" {
  type        = string
  description = "Path inside the Git repository that Flux should reconcile for this cluster"
  default     = "clusters/homelab"
}

variable "flux_namespace" {
  type        = string
  description = "Namespace where Flux components are installed"
  default     = "flux-system"
}

variable "sync_interval" {
  type        = string
  description = "Flux reconciliation interval"
  default     = "1m0s"
}

variable "flux_version" {
  type        = string
  description = "Flux version to bootstrap"
  default     = "v2.9.1"
}

variable "bootstrap_timeout" {
  type        = string
  description = "Timeout for Flux bootstrap operations"
  default     = "10m"
}

variable "embedded_manifests" {
  type        = bool
  description = "Use manifests embedded in the provider instead of downloading them from GitHub"
  default     = false
}

variable "network_policy" {
  type        = bool
  description = "Whether Flux should install restrictive network policies"
  default     = true
}

variable "watch_all_namespaces" {
  type        = bool
  description = "Whether Flux controllers should watch all namespaces"
  default     = true
}

variable "cluster_domain" {
  type        = string
  description = "Internal cluster DNS domain"
  default     = "cluster.local"
}

variable "secret_name" {
  type        = string
  description = "Kubernetes secret name used by Flux for Git credentials"
  default     = "flux-system"
}

variable "recurse_submodules" {
  type        = bool
  description = "Whether Flux should recurse Git submodules"
  default     = false
}

variable "disable_secret_creation" {
  type        = bool
  description = "Use an existing Kubernetes secret instead of creating one during bootstrap"
  default     = false
}

variable "components" {
  type        = set(string)
  description = "Core Flux components to install"
  default = [
    "source-controller",
    "kustomize-controller",
    "helm-controller",
    "notification-controller"
  ]
}

variable "components_extra" {
  type        = set(string)
  description = "Extra Flux components to install"
  default     = []
}

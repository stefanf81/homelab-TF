resource "flux_bootstrap_git" "this" {
  path      = var.cluster_path
  namespace = var.flux_namespace
  interval  = var.sync_interval
  version   = var.flux_version

  components       = var.components
  components_extra = var.components_extra

  embedded_manifests     = var.embedded_manifests
  network_policy         = var.network_policy
  watch_all_namespaces   = var.watch_all_namespaces
  cluster_domain         = var.cluster_domain
  secret_name            = var.secret_name
  recurse_submodules     = var.recurse_submodules
  disable_secret_creation = var.disable_secret_creation

  timeouts = {
    create = var.bootstrap_timeout
    update = var.bootstrap_timeout
    delete = var.bootstrap_timeout
  }
}

output "flux_namespace" {
  value       = var.flux_namespace
  description = "Namespace where Flux is bootstrapped"
}

output "cluster_path" {
  value       = var.cluster_path
  description = "Repository path Flux reconciles for this cluster"
}

terraform {
  required_providers {
    flux = {
      source  = "fluxcd/flux"
      version = "1.9.1"
    }
  }
}

provider "flux" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }

  git = {
    url = var.git_url
    branch = var.git_branch
    author_name  = var.git_author_name
    author_email = var.git_author_email

    http = {
      username = var.git_http_username
      password = var.git_http_password
    }
  }
}

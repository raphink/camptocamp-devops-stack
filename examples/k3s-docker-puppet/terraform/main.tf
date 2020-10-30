locals {
  repo_url        = "https://github.com/raphink/camptocamp-devops-stack.git"
  target_revision = "puppet"

  base_domain                        = module.cluster.base_domain
  kubernetes_host                    = module.cluster.kubernetes_host
  kubernetes_client_certificate      = module.cluster.kubernetes_client_certificate
  kubernetes_client_key              = module.cluster.kubernetes_client_key
  kubernetes_cluster_ca_certificate  = module.cluster.kubernetes_cluster_ca_certificate
  kubernetes_vault_auth_backend_path = module.cluster.kubernetes_vault_auth_backend_path
}

module "cluster" {
  source = "git::https://github.com/camptocamp/camptocamp-devops-stack.git//modules/k3s-docker?ref=HEAD"

  cluster_name = terraform.workspace
  node_count   = 1

  repo_url        = local.repo_url
  target_revision = local.target_revision
}

provider "kubernetes-alpha" {
  host                   = local.kubernetes_host
  client_certificate     = local.kubernetes_client_certificate
  client_key             = local.kubernetes_client_key
  cluster_ca_certificate = local.kubernetes_cluster_ca_certificate
}

resource "kubernetes_manifest" "project_apps" {
  provider = kubernetes-alpha

  manifest = {
    "apiVersion" = "argoproj.io/v1alpha1"
    "kind"       = "Application"
    "metadata" = {
      "name"      = "project-apps"
      "namespace" = "argocd"
      "annotations" = {
        "argocd.argoproj.io/sync-wave" = "15"
      }
    }
    "spec" = {
      "project" = "default"
      "source" = {
        "path"           = "examples/k3s-docker-demo-app/argocd/project-apps"
        "repoURL"        = local.repo_url
        "targetRevision" = local.target_revision
        "helm" = {
          "values" = <<EOT
---
spec:
  source:
    repoURL: ${local.repo_url}
    targetRevision: ${local.target_revision}

baseDomain: ${local.base_domain}
          EOT
        }
      }
      "destination" = {
        "namespace" = "default"
        "server"    = "https://kubernetes.default.svc"
      }
      "syncPolicy" = {
        "automated" = {
          "selfHeal" = true
        }
      }
    }
  }
}

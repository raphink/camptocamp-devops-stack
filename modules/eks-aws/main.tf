locals {
  base_domain                       = var.base_domain
  kubernetes_host                   = data.aws_eks_cluster.cluster.endpoint
  kubernetes_cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  kubernetes_token                  = data.aws_eks_cluster_auth.cluster.token
}

data "aws_eks_cluster" "cluster" {
  name = module.cluster.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.cluster.cluster_id
}

provider "helm" {
  kubernetes {
    host                   = local.kubernetes_host
    cluster_ca_certificate = local.kubernetes_cluster_ca_certificate
    token                  = local.kubernetes_token
  }
}

provider "kubernetes" {
  host                   = local.kubernetes_host
  cluster_ca_certificate = local.kubernetes_cluster_ca_certificate
  token                  = local.kubernetes_token
  load_config_file       = false
}

provider "kubernetes-alpha" {
  host                   = local.kubernetes_host
  cluster_ca_certificate = local.kubernetes_cluster_ca_certificate
  token                  = local.kubernetes_token
}

module "cluster" {
  source  = "terraform-aws-modules/eks/aws"
  version = "13.1.0"

  cluster_name                         = var.cluster_name
  cluster_version                      = "1.17"
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  subnets                              = var.subnets
  vpc_id                               = var.vpc_id
  enable_irsa                          = true
  write_kubeconfig                     = false
  worker_groups                        = var.worker_groups
  map_roles                            = var.map_roles
}

resource "helm_release" "argocd" {
  name              = "argocd"
  repository        = "https://argoproj.github.io/argo-helm"
  chart             = "argo-cd"
  version           = "2.7.4"
  namespace         = "argocd"
  dependency_update = true
  create_namespace  = true

  values = [
    <<EOT
---
installCRDs: false
server:
  config:
    resource.customizations: |
      networking.k8s.io/Ingress:
        health.lua: |
          hs = {}
          hs.status = "Healthy"
          return hs
  EOT
  ]

  depends_on = [
    module.cluster,
  ]
}

resource "random_password" "oauth2_cookie_secret" {
  length  = 16
  special = false
}

resource "kubernetes_manifest" "app_of_apps" {
  provider = kubernetes-alpha

  manifest = {
    "apiVersion" = "argoproj.io/v1alpha1"
    "kind"       = "Application"
    "metadata" = {
      "name"      = "apps"
      "namespace" = "argocd"
      "annotations" = {
        "argocd.argoproj.io/sync-wave" = "5"
      }
    }
    "spec" = {
      "project" = "default"
      "source" = {
        "path"           = "argocd/apps"
        "repoURL"        = var.repo_url
        "targetRevision" = var.target_revision
        "helm" = {
          "values" = templatefile("${path.module}/values.tmpl.yaml",
            {
              cluster_name                    = var.cluster_name,
              base_domain                     = var.base_domain,
              repo_url                        = var.repo_url,
              target_revision                 = var.target_revision,
              aws_default_region              = data.aws_region.current.name,
              cert_manager_assumable_role_arn = module.iam_assumable_role_cert_manager.this_iam_role_arn,
              cognito_user_pool_id            = var.cognito_user_pool_id
              cognito_user_pool_client_id     = aws_cognito_user_pool_client.client.id
              cognito_user_pool_client_secret = aws_cognito_user_pool_client.client.client_secret
              cookie_secret                   = random_password.oauth2_cookie_secret.result
            }
          )
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

  depends_on = [
    helm_release.argocd,
  ]
}

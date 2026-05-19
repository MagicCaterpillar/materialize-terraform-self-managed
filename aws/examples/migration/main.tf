# =============================================================================
# Migration Reference Configuration
# =============================================================================
#
# This file serves as a reference for creating your new Terraform configuration.
# Copy this file and adapt the values to match your existing infrastructure.
#
# IMPORTANT: The module paths in this configuration must match where the state
# migration will move resources TO. If you change module names (e.g., rename
# "module.networking" to "module.vpc"), update your state mv commands accordingly.
#
# =============================================================================
#
# MIGRATION STRATEGY FOR ZERO-DOWNTIME
# =============================================================================
#
# This configuration is pre-configured to MATCH the default infrastructure to
# minimize changes during migration. Key settings:
#
# 1. NAT Gateways: Keeps 3 NAT gateways (one per AZ) - matches old defaults setup
# 2. Node Groups: Keeps existing node groups, Karpenter commented out
# 3. Instance Names: Update locals to match the old Materialize instances
#
# After successful migration, you can gradually adopt new features:
# - Enable Karpenter for autoscaling
# - Update node group configurations
#
# =============================================================================

# -----------------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------------

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # MIGRATION: default_tags omitted to match old module (which didn't use them).
  # After migration is verified, uncomment to apply tags to all resources:
  # default_tags {
  #   tags = var.tags
  # }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
    }
  }
}

# lazy_load = true lets alekc/kubectl v2.4.0+ defer kubeconfig resolution
# (which is strict at provider-configure since v2.3.0) until first use. Without
# it, same-root cluster-plus-manifests applies fail at plan with an empty REST
# config because module.eks outputs are unknown before the cluster exists. See:
# https://registry.terraform.io/providers/alekc/kubectl/latest/docs#troubleshooting
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
  }

  load_config_file = false
  lazy_load        = true
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
# State path: module.networking.module.vpc.*
#
# Update these values to match your existing VPC configuration.
# Run: aws ec2 describe-vpcs --vpc-ids <your-vpc-id> to get current values.

module "networking" {
  source      = "../../modules/networking"
  name_prefix = var.name_prefix

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
  enable_vpc_endpoints = var.enable_vpc_endpoints

  tags = var.tags
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
# State path: module.eks.module.eks.*
#
# Update cluster_version to match your existing cluster.
# Run: aws eks describe-cluster --name <your-cluster> to get current values.

module "eks" {
  source      = "../../modules/eks"
  name_prefix = var.name_prefix

  cluster_version                          = var.cluster_version
  vpc_id                                   = module.networking.vpc_id
  private_subnet_ids                       = module.networking.private_subnet_ids
  cluster_enabled_log_types                = ["api", "audit", "authenticator", "controllerManager", "scheduler"] # MIGRATION: Match old module defaults
  enable_cluster_creator_admin_permissions = true
  materialize_node_ingress_cidrs           = var.ingress_cidr_blocks
  k8s_apiserver_authorized_networks        = var.k8s_apiserver_authorized_networks

  tags = var.tags

  depends_on = [module.networking]
}

# -----------------------------------------------------------------------------
# Base Node Group (for CoreDNS and system workloads)
# -----------------------------------------------------------------------------
# State path: module.base_node_group.module.node_group.*
#
# MIGRATION: This is equivalent to your old "{prefix}-system" node group.
# Update instance_types, min_size, max_size to match your existing setup.

module "base_node_group" {
  source = "../../modules/eks-node-group"

  cluster_name = module.eks.cluster_name
  subnet_ids   = module.networking.private_subnet_ids
  # MIGRATION: The old EKS module used name_prefix as the node group name
  # and "${name_prefix}-system" as the launch template name. Keeping these
  # ensures no replacement of node groups or launch templates.
  node_group_name                   = var.name_prefix
  launch_template_name              = "${var.name_prefix}-system"
  instance_types                    = var.base_instance_types
  swap_enabled                      = false
  min_size                          = var.base_node_min_size
  max_size                          = var.base_node_max_size
  desired_size                      = var.base_node_desired_size
  labels                            = local.base_node_labels
  cluster_service_cidr              = module.eks.cluster_service_cidr
  cluster_primary_security_group_id = module.eks.node_security_group_id
  aws_region                        = var.aws_region
  aws_profile                       = var.aws_profile

  tags = var.tags
}

# MIGRATION: CoreDNS module is commented out during migration because it's a NEW
# module that didn't exist in the old setup. EKS manages CoreDNS by default.
# After migration is verified, uncomment this to manage CoreDNS via Terraform.
#
# module "coredns" {
#   source = "../../../kubernetes/modules/coredns"
#
#   node_selector                      = local.base_node_labels
#   disable_default_coredns_autoscaler = false
#   kubeconfig_data                    = local.kubeconfig_data
#
#   depends_on = [module.eks, module.base_node_group, module.networking]
# }

# -----------------------------------------------------------------------------
# Materialize Node Group
# -----------------------------------------------------------------------------
# State path: module.mz_node_group.module.node_group.*
#
# MIGRATION: This replaces your old materialize_node_group.
# Update instance_types, min_size, max_size to match your existing setup.

module "mz_node_group" {
  source = "../../modules/eks-node-group"

  cluster_name    = module.eks.cluster_name
  subnet_ids      = module.networking.private_subnet_ids
  node_group_name = "${var.name_prefix}-mz-swap"
  instance_types  = var.mz_instance_types
  swap_enabled    = true
  min_size        = var.mz_node_min_size
  max_size        = var.mz_node_max_size
  desired_size    = var.mz_node_desired_size
  labels          = local.materialize_node_labels
  # MIGRATION: Taints commented out - the old module didn't set EKS-level taints.
  # After migration is verified, uncomment to enable taints.
  # node_taints                       = local.materialize_node_taints
  cluster_service_cidr              = module.eks.cluster_service_cidr
  cluster_primary_security_group_id = module.eks.node_security_group_id
  aws_region                        = var.aws_region
  aws_profile                       = var.aws_profile

  tags = merge(var.tags, {
    Swap = "true" # MIGRATION: Match old module tag on materialize node group
  })

  depends_on = [module.eks, module.base_node_group]
}

# -----------------------------------------------------------------------------
# Karpenter (Node Autoscaling) - COMMENTED OUT FOR MIGRATION
# -----------------------------------------------------------------------------
# MIGRATION: Karpenter is commented out to preserve your existing node groups.
# After migration is complete and verified, you can:
# 1. Uncomment these modules
# 2. Gradually drain workloads from static node groups to Karpenter
# 3. Remove the mz_node_group module above
#
# Benefits of Karpenter:
# - Automatic scaling based on pod requirements
# - Better bin-packing and cost optimization
# - Faster node provisioning

# module "karpenter" {
#   source = "../../modules/karpenter"
#
#   name_prefix             = var.name_prefix
#   cluster_name            = module.eks.cluster_name
#   cluster_endpoint        = module.eks.cluster_endpoint
#   oidc_provider_arn       = module.eks.oidc_provider_arn
#   cluster_oidc_issuer_url = module.eks.cluster_oidc_issuer_url
#   node_selector           = local.base_node_labels
#
#   depends_on = [module.eks, module.base_node_group, module.networking]
# }
#
# module "ec2nodeclass_generic" {
#   source = "../../modules/karpenter-ec2nodeclass"
#
#   name               = "generic"
#   ami_selector_terms = [{ "alias" : "bottlerocket@latest" }]
#   instance_types     = ["t4g.xlarge"]
#   instance_profile   = module.karpenter.node_instance_profile
#   security_group_ids = [module.eks.node_security_group_id]
#   subnet_ids         = module.networking.private_subnet_ids
#   swap_enabled       = false
#
#   tags = var.tags
#
#   depends_on = [module.karpenter]
# }
#
# module "nodepool_generic" {
#   source = "../../modules/karpenter-nodepool"
#
#   name           = "generic"
#   nodeclass_name = "generic"
#   instance_types = ["t4g.xlarge"]
#   node_labels    = local.generic_node_labels
#   expire_after   = "168h"
#
#   kubeconfig_data = local.kubeconfig_data
#
#   depends_on = [module.karpenter, module.ec2nodeclass_generic, module.coredns]
# }
#
# module "ec2nodeclass_materialize" {
#   source = "../../modules/karpenter-ec2nodeclass"
#
#   name               = "materialize"
#   ami_selector_terms = [{ "alias" : "bottlerocket@latest" }]
#   instance_types     = ["r7gd.2xlarge"]
#   instance_profile   = module.karpenter.node_instance_profile
#   security_group_ids = [module.eks.node_security_group_id]
#   subnet_ids         = module.networking.private_subnet_ids
#   swap_enabled       = true
#
#   tags = var.tags
#
#   depends_on = [module.karpenter]
# }
#
# module "nodepool_materialize" {
#   source = "../../modules/karpenter-nodepool"
#
#   name           = "materialize"
#   nodeclass_name = "materialize"
#   instance_types = ["r7gd.2xlarge"]
#   node_labels    = local.materialize_node_labels
#   node_taints    = local.materialize_node_taints
#   expire_after   = "Never"
#
#   kubeconfig_data = local.kubeconfig_data
#
#   depends_on = [module.karpenter, module.ec2nodeclass_materialize, module.coredns]
# }

# -----------------------------------------------------------------------------
# AWS Load Balancer Controller
# -----------------------------------------------------------------------------

module "aws_lbc" {
  source = "../../modules/aws-lbc"

  name_prefix       = var.name_prefix
  eks_cluster_name  = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  vpc_id            = module.networking.vpc_id
  region            = var.aws_region
  node_selector     = local.generic_node_labels

  depends_on = [module.eks, module.base_node_group]
}

# -----------------------------------------------------------------------------
# Certificate Manager
# -----------------------------------------------------------------------------

module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  node_selector = local.generic_node_labels

  depends_on = [module.networking, module.eks, module.base_node_group, module.aws_lbc]
}

module "self_signed_cluster_issuer" {
  source = "../../../kubernetes/modules/self-signed-cluster-issuer"

  name_prefix = var.name_prefix

  depends_on = [module.cert_manager]
}

# -----------------------------------------------------------------------------
# Database (RDS PostgreSQL)
# -----------------------------------------------------------------------------
# State path: module.database.module.db.module.db_instance.*
#
# MIGRATION: These values MUST match your existing RDS instance exactly,
# otherwise Terraform will try to modify or recreate the database.
#
# Run: aws rds describe-db-instances --db-instance-identifier <your-db-id>

module "database" {
  source = "../../modules/database"

  name_prefix = var.name_prefix

  postgres_version      = var.postgres_version
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage

  database_name     = "materialize"
  database_username = "materialize"
  database_password = var.old_db_password

  multi_az            = var.db_multi_az
  database_subnet_ids = module.networking.private_subnet_ids
  vpc_id              = module.networking.vpc_id

  cluster_name              = module.eks.cluster_name
  cluster_security_group_id = module.eks.cluster_security_group_id
  node_security_group_id    = module.eks.node_security_group_id

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Storage (S3)
# -----------------------------------------------------------------------------
# State path: module.storage.*
#
# MIGRATION: The bucket name includes a random suffix. After migration,
# the random_id resource will be in state and the name will be preserved.

module "storage" {
  source = "../../modules/storage"

  name_prefix = var.name_prefix
  # MIGRATION: Preserve existing lifecycle rules from old module
  bucket_lifecycle_rules = [
    {
      id                                 = "cleanup"
      enabled                            = true
      prefix                             = ""
      transition_days                    = 90
      transition_storage_class           = "STANDARD_IA"
      noncurrent_version_expiration_days = 90
    }
  ]
  bucket_force_destroy = true # Set to false for production!

  enable_bucket_versioning = true # MIGRATION: Match your existing setting
  enable_bucket_encryption = true

  # IRSA configuration
  oidc_provider_arn         = module.eks.oidc_provider_arn
  cluster_oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  service_account_namespace = local.materialize_instance_namespace
  service_account_name      = local.materialize_instance_name

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Materialize Operator
# -----------------------------------------------------------------------------
# State path: module.operator.*

module "operator" {
  source = "../../modules/operator"

  name_prefix    = var.name_prefix
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id

  instance_pod_tolerations = local.materialize_tolerations
  instance_node_selector   = local.materialize_node_labels
  operator_node_selector   = local.generic_node_labels

  depends_on = [module.eks, module.networking, module.mz_node_group]

  install_metrics_server = true

  # MIGRATION: Pass TLS configuration via helm_values to match old module behavior.
  # The old module configured TLS via defaultCertificateSpecs in the operator Helm values.
  helm_values = var.use_self_signed_cluster_issuer ? {
    tls = {
      defaultCertificateSpecs = {
        balancerdExternal = {
          dnsNames = ["balancerd"]
          issuerRef = {
            name = "${var.name_prefix}-root-ca"
            kind = "ClusterIssuer"
          }
        }
        consoleExternal = {
          dnsNames = ["console"]
          issuerRef = {
            name = "${var.name_prefix}-root-ca"
            kind = "ClusterIssuer"
          }
        }
        internal = {
          issuerRef = {
            name = "${var.name_prefix}-root-ca"
            kind = "ClusterIssuer"
          }
        }
      }
    }
  } : {}
}

# -----------------------------------------------------------------------------
# Materialize Instance Namespace (part of operator module in migrated state)
# -----------------------------------------------------------------------------
# State path: module.operator.kubernetes_namespace.instance_namespaces["<namespace>"]
#
# MIGRATION: These resources are managed as part of the operator module structure
# to match the migrated state. They use for_each to support multiple instances.

resource "kubernetes_namespace" "instance_namespaces" {
  for_each = local.materialize_instances

  metadata {
    name = each.value.namespace
  }

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# Materialize Backend Secret (part of operator module in migrated state)
# -----------------------------------------------------------------------------
# State path: module.operator.kubernetes_secret.materialize_backends["<instance_name>"]

resource "kubernetes_secret" "materialize_backends" {
  for_each = local.materialize_instances

  metadata {
    name      = "${each.key}-materialize-backend"
    namespace = each.value.namespace
  }

  data = {
    # MIGRATION: Must match old module's metadata_backend_url exactly.
    # Old module used: postgres://user:pass@host/{database_name}?sslmode=require
    # where database_name = coalesce(instance.database_name, instance.name)
    metadata_backend_url = format(
      "postgres://%s:%s@%s/%s?sslmode=require",
      module.database.db_instance_username,
      urlencode(var.old_db_password),
      module.database.db_instance_endpoint,
      each.value.database_name
    )
    # MIGRATION: Must match old module's persist_backend_url exactly.
    # Old module used: s3://bucket/{environment}-{instance_name}:serviceaccount:{namespace}:{instance_name}
    persist_backend_url = format(
      "s3://%s/%s-%s:serviceaccount:%s:%s",
      module.storage.bucket_name,
      var.environment,
      each.key,
      each.value.namespace,
      each.key
    )
    license_key                       = var.license_key
    external_login_password_mz_system = var.external_login_password_mz_system # This should be set to your existing mz_system user passwordß
  }

  depends_on = [
    kubernetes_namespace.instance_namespaces,
    module.database,
    module.storage,
  ]
}

# -----------------------------------------------------------------------------
# Materialize Instance Manifest (part of operator module in migrated state)
# -----------------------------------------------------------------------------
# State path: module.operator.kubernetes_manifest.materialize_instances["<instance_name>"]
#
# MIGRATION: Uses kubernetes_manifest (not kubectl_manifest) to match migrated state

resource "kubernetes_manifest" "materialize_instances" {
  for_each = local.materialize_instances

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  manifest = {
    apiVersion = "materialize.cloud/v1alpha1"
    kind       = "Materialize"
    metadata = {
      name      = each.key
      namespace = each.value.namespace
    }
    spec = {
      backendSecretName    = "${each.key}-materialize-backend"
      authenticatorKind    = "Password"
      environmentdImageRef = var.environmentd_image_ref
      forceRollout         = var.force_rollout
      requestRollout       = var.request_rollout

      serviceAccountAnnotations = {
        "eks.amazonaws.com/role-arn" = module.storage.materialize_s3_role_arn
      }

      environmentdResourceRequirements = {
        limits = {
          memory = "4Gi"
        }
        requests = {
          cpu    = "2"
          memory = "4Gi"
        }
      }

      balancerdResourceRequirements = {
        limits = {
          memory = "256Mi"
        }
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
      }
    }
  }

  wait {
    fields = {
      "status.resourceId" = ".*"
    }
  }

  depends_on = [
    kubernetes_secret.materialize_backends,
    kubernetes_namespace.instance_namespaces,
    module.operator,
  ]
}

# -----------------------------------------------------------------------------
# Data Source: Materialize Instances (part of operator module in migrated state)
# -----------------------------------------------------------------------------
# State path: module.operator.kubernetes_resource.materialize_instances["<instance_name>"]
#
# MIGRATION: Data source to retrieve instance resource IDs (used by NLB module)

data "kubernetes_resource" "materialize_instances" {
  for_each = local.materialize_instances

  api_version = "materialize.cloud/v1alpha1"
  kind        = "Materialize"

  metadata {
    name      = each.key
    namespace = each.value.namespace
  }

  depends_on = [kubernetes_manifest.materialize_instances]
}

# -----------------------------------------------------------------------------
# Moved Blocks for Migration
# -----------------------------------------------------------------------------
# These moved blocks automatically migrate resources from the old operator module
# structure to the new root-level structure during terraform apply.
# After migration is complete and verified, these blocks can be removed.

moved {
  from = module.operator.kubernetes_namespace.instance_namespaces
  to   = kubernetes_namespace.instance_namespaces
}

moved {
  from = module.operator.kubernetes_secret.materialize_backends
  to   = kubernetes_secret.materialize_backends
}

moved {
  from = module.operator.kubernetes_manifest.materialize_instances
  to   = kubernetes_manifest.materialize_instances
}

moved {
  from = module.operator.kubernetes_job.db_init_job
  to   = kubernetes_job.db_init_job
}

moved {
  from = module.operator.data.kubernetes_resource.materialize_instances
  to   = data.kubernetes_resource.materialize_instances
}

# -----------------------------------------------------------------------------
# Network Load Balancer
# -----------------------------------------------------------------------------
# State path: module.nlb["<instance_name>"].*
#
# MIGRATION: This uses for_each to match the migrated state structure

module "nlb" {
  for_each = local.materialize_instances
  source   = "../../modules/nlb"

  instance_name = each.key
  name_prefix   = var.name_prefix
  # MIGRATION: Preserve old NLB naming pattern: ${name_prefix}-${instance_name}
  # This avoids NLB recreation during migration. After migration is verified,
  # you can remove this line to use the new name_prefix-based naming.
  nlb_name                         = "${var.name_prefix}-${each.key}"
  namespace                        = each.value.namespace
  subnet_ids                       = var.internal_load_balancer ? module.networking.private_subnet_ids : module.networking.public_subnet_ids
  internal                         = var.internal_load_balancer
  enable_cross_zone_load_balancing = true
  vpc_id                           = module.networking.vpc_id
  mz_resource_id                   = data.kubernetes_resource.materialize_instances[each.key].object.status.resourceId
  node_security_group_id           = module.eks.node_security_group_id
  ingress_cidr_blocks              = var.ingress_cidr_blocks
  # MIGRATION: Old NLBs didn't have security groups. Adding one forces NLB recreation.
  # After migration is verified, set to true to enable NLB security groups.
  create_security_group = false

  depends_on = [module.operator]
}

# -----------------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------------

locals {
  materialize_instance_namespace = var.materialize_instance_namespace
  materialize_instance_name      = var.materialize_instance_name

  # Map of materialize instances for for_each loops
  # MIGRATION: If you have multiple instances, add them here.
  # database_name: The database name used in the old module's metadata_backend_url.
  #   Old module used: coalesce(instance.database_name, instance.name)
  #   If you didn't set database_name explicitly, it defaults to the instance name.
  materialize_instances = {
    (local.materialize_instance_name) = {
      namespace     = local.materialize_instance_namespace
      database_name = local.materialize_instance_name # Defaults to instance name (old module behavior)
    }
  }

  base_node_labels = {
    "workload" = "system" # MIGRATION: Match old module label. Change to "base" after migration.
  }

  # MIGRATION: Set to "system" to match old node labels. The old module didn't set
  # nodeSelectors on helm releases, so pods ran on system nodes. After migration,
  # change to "generic" and add dedicated generic nodes (or use Karpenter).
  generic_node_labels = {
    "workload" = "system"
  }

  materialize_node_labels = {
    "materialize.cloud/swap" = "true"
    "workload"               = "materialize-instance"
  }

  materialize_tolerations = [
    {
      key      = "materialize.cloud/workload"
      value    = "materialize-instance"
      operator = "Equal"
      effect   = "NoSchedule"
    }
  ]

  metadata_backend_url = format(
    "postgres://%s:%s@%s/%s?sslmode=require",
    module.database.db_instance_username,
    urlencode(var.old_db_password),
    module.database.db_instance_endpoint,
    local.materialize_instance_name
  )

  persist_backend_url = format(
    "s3://%s/%s-%s:serviceaccount:%s:%s",
    module.storage.bucket_name,
    var.environment,
    local.materialize_instance_name,
    local.materialize_instance_namespace,
    local.materialize_instance_name
  )

}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

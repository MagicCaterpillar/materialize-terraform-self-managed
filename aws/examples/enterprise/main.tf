provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
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

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
  }

  load_config_file = false
}

# 1. Create network infrastructure
module "networking" {
  source      = "../../modules/networking"
  name_prefix = var.name_prefix

  vpc_cidr             = "10.0.0.0/16"
  availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_vpc_endpoints = true

  tags = var.tags
}

# 2. Create EKS cluster
module "eks" {
  source                                   = "../../modules/eks"
  name_prefix                              = var.name_prefix
  cluster_version                          = "1.33"
  vpc_id                                   = module.networking.vpc_id
  private_subnet_ids                       = module.networking.private_subnet_ids
  cluster_enabled_log_types                = ["api", "audit"]
  enable_cluster_creator_admin_permissions = true
  materialize_node_ingress_cidrs           = [module.networking.vpc_cidr_block]
  k8s_apiserver_authorized_networks        = var.k8s_apiserver_authorized_networks
  tags                                     = var.tags
}

# 2.1 Create base node group for Karpenter and coredns
module "base_node_group" {
  source = "../../modules/eks-node-group"

  cluster_name                      = module.eks.cluster_name
  subnet_ids                        = module.networking.private_subnet_ids
  node_group_name                   = "${var.name_prefix}-base"
  instance_types                    = local.instance_types_base
  swap_enabled                      = false
  min_size                          = 2
  max_size                          = 3
  desired_size                      = 2
  labels                            = local.base_node_labels
  cluster_service_cidr              = module.eks.cluster_service_cidr
  cluster_primary_security_group_id = module.eks.node_security_group_id
  aws_region                        = var.aws_region
  aws_profile                       = var.aws_profile
  tags                              = var.tags
}

# 2.1.1 Install VPC CNI with Network Policy support
module "vpc_cni" {
  source = "../../modules/vpc-cni"

  name_prefix       = var.name_prefix
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  kubeconfig_data   = local.kubeconfig_data

  enable_network_policy    = true
  enable_policy_event_logs = true

  tags = var.tags

  depends_on = [module.base_node_group]
}

module "coredns" {
  source = "../../../kubernetes/modules/coredns"

  node_selector = local.base_node_labels
  # in aws coredns autoscaler deployment doesn't exist
  disable_default_coredns_autoscaler = false
  kubeconfig_data                    = local.kubeconfig_data
  cluster_identifier                 = module.eks.cluster_name

  depends_on = [
    module.base_node_group,
    module.vpc_cni,
  ]
}

# 2.2 Install Karpenter to manage creation of additional nodes
module "karpenter" {
  source = "../../modules/karpenter"

  name_prefix             = var.name_prefix
  cluster_name            = module.eks.cluster_name
  cluster_endpoint        = module.eks.cluster_endpoint
  oidc_provider_arn       = module.eks.oidc_provider_arn
  cluster_oidc_issuer_url = module.eks.cluster_oidc_issuer_url
  node_selector           = local.base_node_labels

  depends_on = [module.base_node_group]
}

# Create a generic nodeclass and nodepool for all workloads except Materialize.
module "ec2nodeclass_generic" {
  source = "../../modules/karpenter-ec2nodeclass"

  name               = local.nodeclass_name_generic
  ami_selector_terms = local.ami_selector_terms
  instance_types     = local.instance_types_generic
  instance_profile   = module.karpenter.node_instance_profile
  security_group_ids = [module.eks.node_security_group_id]
  subnet_ids         = module.networking.private_subnet_ids
  swap_enabled       = false
  tags               = var.tags
}

module "nodepool_generic" {
  source = "../../modules/karpenter-nodepool"

  name           = local.nodeclass_name_generic
  nodeclass_name = local.nodeclass_name_generic
  instance_types = local.instance_types_generic
  node_labels    = local.generic_node_labels
  expire_after   = "168h"

  kubeconfig_data = local.kubeconfig_data

  depends_on = [
    module.ec2nodeclass_generic,
    module.coredns,
  ]
}

# Create a dedicated nodeclass and nodepool for Materialize pods.
module "ec2nodeclass_materialize" {
  source = "../../modules/karpenter-ec2nodeclass"

  name               = local.nodeclass_name_materialize
  ami_selector_terms = local.ami_selector_terms
  instance_types     = local.instance_types_materialize
  instance_profile   = module.karpenter.node_instance_profile
  security_group_ids = [module.eks.node_security_group_id]
  subnet_ids         = module.networking.private_subnet_ids
  swap_enabled       = true
  tags               = var.tags
}

module "nodepool_materialize" {
  source = "../../modules/karpenter-nodepool"

  name           = local.nodeclass_name_materialize
  nodeclass_name = local.nodeclass_name_materialize
  instance_types = local.instance_types_materialize
  node_labels    = local.materialize_node_labels
  node_taints    = local.materialize_node_taints
  # WARNING: setting this to any value other than Never may cause
  # downtime. Karpenter will remove nodes regardless of whether they
  # have pods with do-not-disrupt labels. If you set this to any duration
  # you should ensure that you always gracefully roll nodes during a
  # materialize rollout. To do this cordon the node, perform an upgrade or
  # forced rollout of all materialize instances that may be using the node pool.
  # the node should have all pods removed from it and be consolidated. You may
  # also delete the node after all clusterd and environmentd pods have been moved off.
  expire_after = "Never"

  kubeconfig_data = local.kubeconfig_data

  depends_on = [
    module.ec2nodeclass_materialize,
    module.coredns,
  ]
}

# 3. Install AWS Load Balancer Controller
module "aws_lbc" {
  source = "../../modules/aws-lbc"

  name_prefix       = var.name_prefix
  eks_cluster_name  = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  vpc_id            = module.networking.vpc_id
  region            = var.aws_region
  node_selector     = local.generic_node_labels

  tags = var.tags

  depends_on = [
    module.nodepool_generic,
    module.coredns,
  ]
}

# 4. Install EBS CSI Driver for dynamic EBS volume provisioning
module "ebs_csi_driver" {
  source = "../../modules/ebs-csi-driver"

  name_prefix       = var.name_prefix
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  node_selector     = local.generic_node_labels

  tags = var.tags

  depends_on = [
    module.base_node_group,
    module.coredns,
  ]
}

# 5. Install Certificate Manager for TLS
module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  node_selector = local.generic_node_labels

  depends_on = [
    module.eks,
    module.nodepool_generic,
    module.coredns,
  ]
}

# Always-created self-signed cluster issuer. Used for the internal mTLS cert
# spec (which has *.cluster.local SANs that public ACME issuers reject) and as
# the default for the browser-facing certs when var.cert_issuer_ref is null.
module "self_signed_cluster_issuer" {
  source = "../../../kubernetes/modules/self-signed-cluster-issuer"

  name_prefix = var.name_prefix

  depends_on = [
    module.cert_manager,
  ]
}

# 6. Install Materialize Operator
module "operator" {
  source = "../../modules/operator"

  name_prefix    = var.name_prefix
  aws_region     = var.aws_region
  aws_account_id = data.aws_caller_identity.current.account_id

  # tolerations and node selector for all mz instance workloads on AWS
  instance_pod_tolerations = local.materialize_tolerations
  instance_node_selector   = local.materialize_node_labels

  # node selector for operator and metrics-server workloads
  operator_node_selector = local.generic_node_labels

  enable_network_policies = true
  operator_namespace      = local.operator_namespace
  monitoring_namespace    = local.monitoring_namespace

  # Enable Prometheus scrape annotations when observability is enabled
  helm_values = var.enable_observability ? {
    observability = {
      enabled = true
      prometheus = {
        scrapeAnnotations = {
          enabled = true
        }
      }
    }
  } : {}

  depends_on = [
    module.nodepool_generic,
    module.coredns,
    module.vpc_cni,
  ]
}

resource "random_password" "database_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "external_login_password_mz_system" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "ory_database_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# 7. Setup dedicated database instance for Materialize
module "database" {
  source                    = "../../modules/database"
  name_prefix               = var.name_prefix
  postgres_version          = "18"
  backup_retention_period   = 35
  instance_class            = "db.t3.large"
  allocated_storage         = 50
  max_allocated_storage     = 100
  database_name             = "materialize"
  database_username         = "materialize"
  database_password         = random_password.database_password.result
  multi_az                  = false
  database_subnet_ids       = module.networking.private_subnet_ids
  vpc_id                    = module.networking.vpc_id
  cluster_name              = module.eks.cluster_name
  cluster_security_group_id = module.eks.cluster_security_group_id
  node_security_group_id    = module.eks.node_security_group_id

  tags = var.tags
}

# Separate RDS instance for Ory Kratos
module "ory_kratos_database" {
  source                    = "../../modules/database"
  name_prefix               = "${var.name_prefix}-ory-kratos"
  postgres_version          = "18"
  backup_retention_period   = 35
  instance_class            = "db.t3.small"
  allocated_storage         = 20
  max_allocated_storage     = 50
  database_name             = "kratos"
  database_username         = "oryadmin"
  database_password         = random_password.ory_database_password.result
  multi_az                  = false
  database_subnet_ids       = module.networking.private_subnet_ids
  vpc_id                    = module.networking.vpc_id
  cluster_name              = module.eks.cluster_name
  cluster_security_group_id = module.eks.cluster_security_group_id
  node_security_group_id    = module.eks.node_security_group_id

  tags = var.tags
}

# Separate RDS instance for Ory Hydra
module "ory_hydra_database" {
  source                    = "../../modules/database"
  name_prefix               = "${var.name_prefix}-ory-hydra"
  postgres_version          = "18"
  backup_retention_period   = 35
  instance_class            = "db.t3.small"
  allocated_storage         = 20
  max_allocated_storage     = 50
  database_name             = "hydra"
  database_username         = "oryadmin"
  database_password         = random_password.ory_database_password.result
  multi_az                  = false
  database_subnet_ids       = module.networking.private_subnet_ids
  vpc_id                    = module.networking.vpc_id
  cluster_name              = module.eks.cluster_name
  cluster_security_group_id = module.eks.cluster_security_group_id
  node_security_group_id    = module.eks.node_security_group_id

  tags = var.tags
}

# 8. Setup S3 bucket for Materialize
module "storage" {
  source                 = "../../modules/storage"
  name_prefix            = var.name_prefix
  bucket_lifecycle_rules = []
  bucket_force_destroy   = true

  # For testing purposes, we are disabling versioning to allow for easier cleanup.
  # SSE-S3 encryption remains enabled by default for this example.
  enable_bucket_versioning = false
  enable_bucket_encryption = true

  # IRSA configuration
  oidc_provider_arn         = module.eks.oidc_provider_arn
  cluster_oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  service_account_namespace = local.materialize_instance_namespace
  service_account_name      = local.materialize_instance_name

  tags = var.tags
}

# 9. Setup Materialize instance
module "materialize_instance" {
  source               = "../../../kubernetes/modules/materialize-instance"
  instance_name        = local.materialize_instance_name
  instance_namespace   = local.materialize_instance_namespace
  metadata_backend_url = local.metadata_backend_url
  persist_backend_url  = local.persist_backend_url

  enable_network_policies = true
  monitoring_namespace    = local.monitoring_namespace

  # Rollout configuration
  force_rollout   = var.force_rollout
  request_rollout = var.request_rollout

  # Use OIDC authentication via Ory Hydra. The external_login_password is still required
  # as a fallback for the mz_system admin user.
  external_login_password_mz_system = random_password.external_login_password_mz_system.result
  authenticator_kind                = "Oidc"

  # AWS IAM role annotation for service account
  service_account_annotations = {
    "eks.amazonaws.com/role-arn" = module.storage.materialize_s3_role_arn
  }

  license_key = var.license_key

  issuer_ref = local.cert_issuer
  # Internal mTLS has cluster.local SANs which public ACME issuers can't sign,
  # so always route the internal cert spec through the self-signed cluster issuer.
  internal_issuer_ref = {
    name = module.self_signed_cluster_issuer.issuer_name
    kind = "ClusterIssuer"
  }

  # Browser-facing SAN. balancerd is intentionally omitted; see README.
  console_extra_dns_names = [var.materialize_console_hostname]

  # OIDC configuration. Points Materialize at Hydra for JWT validation.
  # client_id comes from the Hydra Maester-generated secret (Hydra Maester auto-
  # generates a UUID client_id; the installed CRD version does not support setting
  # it explicitly).
  # See: https://materialize.com/docs/security/self-managed/sso/
  # system_parameters can also set any of the other Materialize configuration
  # parameters listed at:
  # https://materialize.com/docs/sql/alter-system-set/#key-configuration-parameters
  system_parameters = {
    oidc_issuer               = module.ory.hydra_external_url
    oidc_audience             = jsonencode([module.ory.oauth2_client_id])
    oidc_authentication_claim = "email"
    console_oidc_client_id    = module.ory.oauth2_client_id
    console_oidc_scopes       = "openid email"
  }

  depends_on = [
    module.operator,
    module.aws_lbc,
    module.nodepool_materialize,
    module.coredns,
  ]
}

# 10. Setup Observability Stack (Prometheus + Grafana)
module "prometheus" {
  count  = var.enable_observability ? 1 : 0
  source = "../../../kubernetes/modules/prometheus"

  namespace        = local.monitoring_namespace
  create_namespace = false # operator creates the "monitoring" namespace
  node_selector    = local.generic_node_labels
  storage_class    = module.ebs_csi_driver.storage_class_name

  depends_on = [
    module.operator,
    module.nodepool_generic,
    module.coredns,
    module.ebs_csi_driver,
  ]
}

module "grafana" {
  count  = var.enable_observability ? 1 : 0
  source = "../../../kubernetes/modules/grafana"

  namespace = local.monitoring_namespace
  # operator creates the "monitoring" namespace
  create_namespace = false
  storage_class    = module.ebs_csi_driver.storage_class_name
  prometheus_url   = module.prometheus[0].prometheus_url
  node_selector    = local.generic_node_labels
}

# 11. Setup dedicated NLB for Materialize instance
module "materialize_nlb" {
  source = "../../modules/nlb"

  instance_name                    = local.materialize_instance_name
  name_prefix                      = var.name_prefix
  namespace                        = local.materialize_instance_namespace
  subnet_ids                       = var.internal_load_balancer ? module.networking.private_subnet_ids : module.networking.public_subnet_ids
  internal                         = var.internal_load_balancer
  enable_cross_zone_load_balancing = true
  vpc_id                           = module.networking.vpc_id
  mz_resource_id                   = module.materialize_instance.instance_resource_id
  node_security_group_id           = module.eks.node_security_group_id
  ingress_cidr_blocks              = var.ingress_cidr_blocks

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Ory: Identity & OAuth2 (Kratos + Hydra + selfservice UI)
# -----------------------------------------------------------------------------
#
# Everything Ory-related lives in the ory-stack composite module: namespace,
# OEL pull secret, cert-manager Certificates, Kratos / Hydra / selfservice UI,
# the public LoadBalancers, plus the Materialize bridge (OAuth2Client CRD,
# network policies, console HTTPS LB). The example only feeds it the cloud-
# specific bits (DSNs, LB annotations, the cert issuer) and consumes the
# OIDC issuer URL + OAuth2 client id from its outputs.
module "ory" {
  source = "../../../kubernetes/modules/ory-stack"

  namespace = local.ory_namespace

  hydra_fqdn  = var.ory_hydra_hostname
  kratos_fqdn = var.ory_kratos_hostname
  ui_fqdn     = var.ory_ui_hostname

  kratos_dsn = local.ory_kratos_dsn
  hydra_dsn  = local.ory_hydra_dsn

  oel_registry  = var.ory_oel_registry
  oel_image_tag = var.ory_oel_image_tag
  oel_key_file  = var.ory_oel_key_file

  cert_issuer_ref                 = local.cert_issuer
  cert_issuer_signs_cluster_local = var.cert_issuer_ref == null

  # Materialize integration: OAuth2 client CRD, network policies, console LB.
  materialize_namespace            = local.materialize_instance_namespace
  materialize_instance_name        = local.materialize_instance_name
  materialize_instance_resource_id = module.materialize_instance.instance_resource_id
  materialize_console_fqdn         = var.materialize_console_hostname

  # AWS Load Balancer Controller settings. The AWS LBC provisions an NLB based
  # on these annotations; the load_balancer_class routes the Service through
  # the AWS LBC, and externalTrafficPolicy = Local preserves client source IPs.
  lb_annotations             = local.ory_lb_annotations
  lb_load_balancer_class     = "service.k8s.aws/nlb"
  lb_external_traffic_policy = "Local"

  node_selector = local.generic_node_labels

  # Optional upstream OIDC providers (Okta, Entra, Auth0, Google, etc.) exposed
  # as social sign-in buttons on the selfservice UI.
  upstream_oidc_providers = var.upstream_oidc_providers

  depends_on = [
    module.coredns,
    module.aws_lbc,
  ]
}

locals {
  materialize_instance_namespace = "materialize-environment"
  operator_namespace             = "materialize"
  materialize_instance_name      = "main"

  monitoring_namespace = "monitoring"

  # Common node scheduling configuration
  base_node_labels = {
    "workload" = "base"
  }

  generic_node_labels = {
    "workload" = "generic"
  }

  materialize_node_labels = {
    "materialize.cloud/swap" = "true"
    "workload"               = "materialize-instance"
  }

  materialize_node_taints = [
    {
      key    = "materialize.cloud/workload"
      value  = "materialize-instance"
      effect = "NoSchedule"
    }
  ]

  materialize_tolerations = [
    {
      key      = "materialize.cloud/workload"
      value    = "materialize-instance"
      operator = "Equal"
      effect   = "NoSchedule"
    }
  ]

  database_statement_timeout = "15min"

  metadata_backend_url = format(
    "postgres://%s:%s@%s/%s?sslmode=require&options=-c%%20statement_timeout%%3D%s",
    module.database.db_instance_username,
    urlencode(random_password.database_password.result),
    module.database.db_instance_endpoint,
    module.database.db_instance_name,
    local.database_statement_timeout
  )

  persist_backend_url = format(
    "s3://%s/system:serviceaccount:%s:%s",
    module.storage.bucket_name,
    local.materialize_instance_namespace,
    local.materialize_instance_name
  )

  ami_selector_terms = [{ "alias" : "bottlerocket@latest" }]

  instance_types_base        = ["t4g.medium"]
  instance_types_generic     = ["t4g.xlarge"]
  instance_types_materialize = ["r7gd.2xlarge"]

  nodeclass_name_generic     = "generic"
  nodeclass_name_materialize = "materialize"

  kubeconfig_data = jsonencode({
    "apiVersion" : "v1",
    "kind" : "Config",
    "clusters" : [
      {
        "name" : module.eks.cluster_name,
        "cluster" : {
          "certificate-authority-data" : module.eks.cluster_certificate_authority_data,
          "server" : module.eks.cluster_endpoint,
        },
      },
    ],
    "contexts" : [
      {
        "name" : module.eks.cluster_name,
        "context" : {
          "cluster" : module.eks.cluster_name,
          "user" : module.eks.cluster_name,
        },
      },
    ],
    "current-context" : module.eks.cluster_name,
    "users" : [
      {
        "name" : module.eks.cluster_name,
        "user" : {
          "exec" : {
            "apiVersion" : "client.authentication.k8s.io/v1beta1",
            "command" : "aws",
            "args" : [
              "eks",
              "get-token",
              "--cluster-name",
              module.eks.cluster_name,
              "--region",
              var.aws_region,
              "--profile",
              var.aws_profile,
            ]
          }
        },
      },
    ],
  })

  # Ory database DSNs
  ory_kratos_dsn = format(
    "postgres://%s:%s@%s/%s?sslmode=require",
    module.ory_kratos_database.db_instance_username,
    urlencode(random_password.ory_database_password.result),
    module.ory_kratos_database.db_instance_endpoint,
    "kratos"
  )

  ory_hydra_dsn = format(
    "postgres://%s:%s@%s/%s?sslmode=require",
    module.ory_hydra_database.db_instance_username,
    urlencode(random_password.ory_database_password.result),
    module.ory_hydra_database.db_instance_endpoint,
    "hydra"
  )

  ory_namespace = "ory"

  # cert-manager ClusterIssuer for browser-facing TLS. Defaults to the built-in
  # self-signed issuer; override via var.cert_issuer_ref to plug in a real one.
  cert_issuer = var.cert_issuer_ref != null ? var.cert_issuer_ref : {
    name = module.self_signed_cluster_issuer.issuer_name
    kind = "ClusterIssuer"
  }

  # AWS Load Balancer Controller annotations for the external/internal NLBs
  # fronting Ory (Hydra public, Kratos public, selfservice UI) and the Materialize
  # console. The AWS LBC provisions these NLBs based on these annotations.
  ory_lb_annotations = merge(
    {
      "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-scheme"          = var.internal_load_balancer ? "internal" : "internet-facing"
    },
    var.internal_load_balancer ? {} : {
      "service.beta.kubernetes.io/aws-load-balancer-ip-address-type" = "ipv4"
    },
  )
}

data "aws_caller_identity" "current" {}

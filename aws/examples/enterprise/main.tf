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


  depends_on = [
    module.networking,
  ]
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
  tags                              = var.tags
}

# 2.1.1 Install VPC CNI with Network Policy support
module "vpc_cni" {
  source = "../../modules/vpc-cni"

  name_prefix       = var.name_prefix
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.cluster_oidc_issuer_url

  enable_network_policy    = true
  enable_policy_event_logs = true

  tags = var.tags

  depends_on = [
    module.eks,
    module.base_node_group,
  ]
}

module "coredns" {
  source = "../../../kubernetes/modules/coredns"

  node_selector = local.base_node_labels
  # in aws coredns autoscaler deployment doesn't exist
  disable_default_coredns_autoscaler = false
  kubeconfig_data                    = local.kubeconfig_data

  depends_on = [
    module.eks,
    module.base_node_group,
    module.networking,
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

  depends_on = [
    module.eks,
    module.base_node_group,
    module.networking,
  ]
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

  depends_on = [
    module.karpenter,
  ]
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
    module.karpenter,
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

  depends_on = [
    module.karpenter,
  ]
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
    module.karpenter,
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
    module.eks,
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
    module.eks,
    module.base_node_group,
    module.coredns,
  ]
}

# 5. Install Certificate Manager for TLS
module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  node_selector = local.generic_node_labels

  depends_on = [
    module.networking,
    module.eks,
    module.nodepool_generic,
    module.aws_lbc,
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
    module.eks,
    module.networking,
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
  postgres_version          = "15"
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
  postgres_version          = "15"
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
  postgres_version          = "15"
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
  # Internal mTLS uses cluster.local SANs which a public ACME issuer can't sign,
  # so always route the internal cert spec through the private (self-signed) CA.
  internal_issuer_ref = local.internal_cert_issuer

  # Include the external console hostname in the cert so browsers accept it.
  console_extra_dns_names   = [var.materialize_console_hostname]
  balancerd_extra_dns_names = [var.materialize_console_hostname]

  # OIDC configuration — points Materialize at Hydra for JWT validation.
  # client_id comes from the Hydra Maester-generated secret (Hydra Maester auto-
  # generates a UUID client_id; the installed CRD version doesn't support setting
  # it explicitly).
  # See: https://materialize.com/docs/security/self-managed/sso/
  system_parameters = {
    oidc_issuer               = local.hydra_external_url
    oidc_audience             = jsonencode([data.kubernetes_secret_v1.oauth2_client.data["CLIENT_ID"]])
    oidc_authentication_claim = "email"
    console_oidc_client_id    = data.kubernetes_secret_v1.oauth2_client.data["CLIENT_ID"]
    console_oidc_scopes       = "openid email"
  }

  depends_on = [
    module.eks,
    module.database,
    module.storage,
    module.networking,
    module.self_signed_cluster_issuer,
    module.operator,
    module.aws_lbc,
    module.nodepool_materialize,
    module.coredns,
    module.ory_hydra,
    kubectl_manifest.materialize_oauth2_client,
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

  depends_on = [
    module.prometheus,
  ]
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

  depends_on = [
    module.materialize_instance
  ]
}

# -----------------------------------------------------------------------------
# Ory: Identity & OAuth2 (Kratos + Hydra)
# -----------------------------------------------------------------------------

# TODO: Update auth mechanism once Materialize private registry is set up.
resource "kubernetes_namespace" "ory" {
  metadata {
    name = "ory"
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret" "ory_oel_registry" {
  metadata {
    name      = "ory-oel-registry"
    namespace = kubernetes_namespace.ory.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "europe-docker.pkg.dev" = {
          auth = base64encode("_json_key:${file(var.ory_oel_key_file)}")
        }
      }
    })
  }
}

module "ory_kratos" {
  source = "../../../kubernetes/modules/ory-kratos"

  namespace        = "ory"
  create_namespace = false
  dsn              = local.ory_kratos_dsn

  # OEL image — registry must be part of repository (Ory Helm chart ignores image.registry)
  image_repository   = "${var.ory_oel_registry}/ory-enterprise-kratos/kratos-oel"
  image_tag          = var.ory_oel_image_tag
  image_pull_secrets = ["ory-oel-registry"]

  # Serve TLS directly in the Kratos pod using cert-manager-issued certs.
  tls_cert_secret_name = "kratos-tls"

  node_selector = local.generic_node_labels

  # Kratos requires at least one identity schema and a default browser return URL
  identity_schemas = {
    "identity.default.schema.json" = jsonencode({
      "$id"     = "https://schemas.ory.sh/presets/kratos/identity.basic.schema.json"
      "$schema" = "http://json-schema.org/draft-07/schema#"
      title     = "Default Identity Schema"
      type      = "object"
      properties = {
        traits = {
          type = "object"
          properties = {
            email = {
              type   = "string"
              format = "email"
              title  = "Email"
              "ory.sh/kratos" = {
                credentials = {
                  password = { identifier = true }
                }
                recovery     = { via = "email" }
                verification = { via = "email" }
              }
            }
          }
          required = ["email"]
        }
      }
    })
  }

  helm_values = {
    kratos = {
      config = {
        serve = {
          # base_url is what Kratos uses when rendering links for the browser
          # (redirects, form action URLs, etc.). Must be a browser-reachable URL.
          public = {
            base_url = local.kratos_external_url
          }
        }
        # Set cookie domain to the parent so cookies work across sibling subdomains
        # (the selfservice UI sends cookies that were set by Kratos and vice versa).
        cookies = {
          domain    = local.cookie_parent_domain
          same_site = "Lax"
        }
        session = {
          cookie = {
            domain    = local.cookie_parent_domain
            same_site = "Lax"
          }
        }
        # Tell Kratos where Hydra's admin API is. Required for Kratos to process
        # login_challenge query parameters that come from Hydra during OIDC flows.
        oauth2_provider = {
          url = "http://hydra-admin.ory.svc.cluster.local:4445"
        }
        selfservice = {
          default_browser_return_url = local.ui_external_url
          # Point Kratos's user-facing flows at the selfservice UI.
          flows = {
            login        = { ui_url = "${local.ui_external_url}/login" }
            registration = { ui_url = "${local.ui_external_url}/registration" }
            recovery     = { ui_url = "${local.ui_external_url}/recovery" }
            verification = { ui_url = "${local.ui_external_url}/verification" }
            settings     = { ui_url = "${local.ui_external_url}/settings" }
            error        = { ui_url = "${local.ui_external_url}/error" }
            logout       = { after = { default_browser_return_url = local.ui_external_url } }
          }
        }
        identity = {
          default_schema_id = "default"
          schemas = [
            {
              id  = "default"
              url = "file:///etc/config/identity.default.schema.json"
            }
          ]
        }
      }
    }
  }

  depends_on = [
    module.eks,
    module.ory_kratos_database,
    module.nodepool_generic,
    module.coredns,
    kubernetes_secret.ory_oel_registry,
    kubernetes_namespace.ory,
    kubectl_manifest.kratos_certificate,
  ]
}

module "ory_hydra" {
  source = "../../../kubernetes/modules/ory-hydra"

  namespace        = "ory"
  create_namespace = false

  dsn        = local.ory_hydra_dsn
  issuer_url = local.hydra_external_url

  # OEL image — registry must be part of repository (Ory Helm chart ignores image.registry)
  image_repository   = "${var.ory_oel_registry}/ory-enterprise/hydra-oel"
  image_tag          = var.ory_oel_image_tag
  image_pull_secrets = ["ory-oel-registry"]

  # Serve TLS directly in the Hydra pod using cert-manager-issued certs.
  tls_cert_secret_name = "hydra-tls"

  # Allow the Materialize console to call Hydra's OIDC endpoints from the browser.
  cors_allowed_origins = ["https://${var.materialize_console_hostname}"]

  # Browser redirects to the selfservice UI for login/consent (external HTTPS URL).
  login_url   = "${local.ui_external_url}/login"
  consent_url = "${local.ui_external_url}/consent"
  logout_url  = "${local.ui_external_url}/logout"

  helm_values = {
    hydra = {
      config = {
        # Issue JWT access tokens so Materialize can validate them via JWKS.
        strategies = {
          access_token = "jwt"
        }
      }
    }
  }

  node_selector = local.generic_node_labels

  depends_on = [
    module.eks,
    module.ory_hydra_database,
    module.ory_kratos,
    module.nodepool_generic,
    module.coredns,
    kubernetes_secret.ory_oel_registry,
    kubectl_manifest.hydra_certificate,
  ]
}

# TLS certificates for Hydra, Kratos, and the selfservice UI, issued by the
# self-signed ClusterIssuer (same one used for Materialize internal TLS).
resource "kubectl_manifest" "hydra_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "hydra-tls"
      namespace = "ory"
    }
    spec = {
      secretName = "hydra-tls"
      # The external hostname covers browser traffic. The cluster-internal SAN
      # is only included with the default self-signed issuer (which can sign
      # cluster.local). When var.cert_issuer_ref is set we assume the customer
      # may be using a public ACME issuer that rejects .cluster.local, so we
      # drop the SAN and route in-cluster clients to Hydra via the public
      # hostname (hairpin NAT through the LB; TLS still validates).
      dnsNames = concat(
        [var.ory_hydra_hostname],
        var.cert_issuer_ref != null ? [] : ["hydra-public.ory.svc.cluster.local"],
      )
      issuerRef = local.cert_issuer
    }
  })

  depends_on = [
    module.self_signed_cluster_issuer,
    kubernetes_namespace.ory,
  ]
}

resource "kubectl_manifest" "kratos_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "kratos-tls"
      namespace = "ory"
    }
    spec = {
      secretName = "kratos-tls"
      # See the equivalent comment on hydra_certificate above. Same trade-off.
      dnsNames = concat(
        [var.ory_kratos_hostname],
        var.cert_issuer_ref != null ? [] : ["kratos-public.ory.svc.cluster.local"],
      )
      issuerRef = local.cert_issuer
    }
  })

  depends_on = [
    module.self_signed_cluster_issuer,
    kubernetes_namespace.ory,
  ]
}

resource "kubectl_manifest" "ui_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "ory-selfservice-ui-tls"
      namespace = "ory"
    }
    spec = {
      secretName = "ory-selfservice-ui-tls"
      dnsNames   = [var.ory_ui_hostname]
      issuerRef  = local.cert_issuer
    }
  })

  depends_on = [
    module.self_signed_cluster_issuer,
    kubernetes_namespace.ory,
  ]
}

# Login + consent UI that sits between Hydra and Kratos.
# Without this, Hydra has no way to authenticate users or collect consent.
module "ory_selfservice_ui" {
  source = "../../../kubernetes/modules/ory-selfservice-ui"

  namespace = "ory"
  # Server-side calls from the UI pod to Kratos's public API. With the default
  # self-signed issuer the cert covers the cluster service URL, so we use it
  # directly. With var.cert_issuer_ref set the cert may only have the external
  # hostname, so we route through it (resolves to the LB IP via public DNS and
  # hairpins back into the cluster).
  kratos_public_url = var.cert_issuer_ref != null ? local.kratos_external_url : module.ory_kratos.public_url
  kratos_admin_url  = module.ory_kratos.admin_url
  # Browser-facing Kratos URL (used when the UI returns redirects or form actions).
  kratos_browser_url = local.kratos_external_url
  hydra_admin_url    = "http://hydra-admin.ory.svc.cluster.local:4445"

  # Serve TLS directly using cert-manager-issued certs.
  tls_cert_secret_name = "ory-selfservice-ui-tls"

  node_selector = local.generic_node_labels

  depends_on = [
    module.ory_kratos,
    module.coredns,
    kubectl_manifest.ui_certificate,
  ]
}

# Allow Materialize pods to reach Ory (Hydra OIDC discovery + JWKS).
resource "kubernetes_network_policy_v1" "materialize_to_ory_egress" {
  metadata {
    name      = "allow-ory-egress"
    namespace = local.materialize_instance_namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ory"
          }
        }
      }
    }
  }

  depends_on = [module.materialize_instance]
}

# Allow Ory pods to receive traffic from Materialize, within the ory namespace,
# and from external LoadBalancers (the Hydra public API and selfservice UI are
# browser-facing and must be reachable from clients outside the cluster).
resource "kubernetes_network_policy_v1" "ory_from_materialize_ingress" {
  metadata {
    name      = "allow-materialize-ingress"
    namespace = "ory"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    # Allow full traffic from Materialize and within the ory namespace.
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.materialize_instance_namespace
          }
        }
      }

      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ory"
          }
        }
      }
    }

    # Allow external traffic (from LoadBalancers) only to Hydra public (4444),
    # Kratos public (4433), and the selfservice UI (3000). Admin ports stay internal.
    ingress {
      from {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }
      ports {
        protocol = "TCP"
        port     = 4444
      }
      ports {
        protocol = "TCP"
        port     = 4433
      }
      ports {
        protocol = "TCP"
        port     = 3000
      }
    }
  }

  depends_on = [kubernetes_namespace.ory]
}

# External LoadBalancer for Kratos's public API. Kratos returns browser-facing URLs
# that redirect here (e.g., form submissions, verification links).
# The admin port (4434) is intentionally NOT exposed — only cluster-internal access.
resource "kubernetes_service_v1" "kratos_public_lb" {
  metadata {
    name        = "kratos-public-lb"
    namespace   = "ory"
    annotations = local.ory_lb_annotations
  }

  spec {
    type                    = "LoadBalancer"
    load_balancer_class     = "service.k8s.aws/nlb"
    external_traffic_policy = "Local"

    selector = {
      "app.kubernetes.io/name"     = "kratos"
      "app.kubernetes.io/instance" = "kratos"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 4433
      protocol    = "TCP"
    }
  }

  depends_on = [module.ory_kratos, module.aws_lbc]
}

# External LoadBalancer for Hydra's public OAuth2/OIDC endpoints.
# The admin port (4445) is intentionally NOT exposed — only cluster-internal access.
resource "kubernetes_service_v1" "hydra_public_lb" {
  metadata {
    name        = "hydra-public-lb"
    namespace   = "ory"
    annotations = local.ory_lb_annotations
  }

  spec {
    type                    = "LoadBalancer"
    load_balancer_class     = "service.k8s.aws/nlb"
    external_traffic_policy = "Local"

    selector = {
      "app.kubernetes.io/name"     = "hydra"
      "app.kubernetes.io/instance" = "hydra"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 4444
      protocol    = "TCP"
    }
  }

  depends_on = [module.ory_hydra, module.aws_lbc]
}

# External LoadBalancer for the Materialize console on port 443 (the console
# redirects away from non-canonical ports, so we need HTTPS on 443 externally).
resource "kubernetes_service_v1" "console_lb_443" {
  metadata {
    name        = "${local.materialize_instance_name}-console-https"
    namespace   = local.materialize_instance_namespace
    annotations = local.ory_lb_annotations
  }

  spec {
    type                    = "LoadBalancer"
    load_balancer_class     = "service.k8s.aws/nlb"
    external_traffic_policy = "Local"

    selector = {
      "materialize.cloud/app"                    = "console"
      "materialize.cloud/mz-resource-id"         = module.materialize_instance.instance_resource_id
      "materialize.cloud/organization-name"      = local.materialize_instance_name
      "materialize.cloud/organization-namespace" = local.materialize_instance_namespace
    }

    port {
      name        = "https"
      port        = 443
      target_port = 8080
      protocol    = "TCP"
    }
  }

  depends_on = [module.materialize_instance, module.aws_lbc]
}

# External LoadBalancer for the selfservice UI (browser-facing login/consent).
resource "kubernetes_service_v1" "ui_lb" {
  metadata {
    name        = "ory-selfservice-ui-lb"
    namespace   = "ory"
    annotations = local.ory_lb_annotations
  }

  spec {
    type                    = "LoadBalancer"
    load_balancer_class     = "service.k8s.aws/nlb"
    external_traffic_policy = "Local"

    selector = {
      "app.kubernetes.io/name"     = "kratos-selfservice-ui-node"
      "app.kubernetes.io/instance" = module.ory_selfservice_ui.service_name
    }

    port {
      name        = "https"
      port        = 443
      target_port = module.ory_selfservice_ui.port
      protocol    = "TCP"
    }
  }

  depends_on = [module.ory_selfservice_ui, module.aws_lbc]
}

# Register an OAuth2 client in Hydra for Materialize.
# Hydra Maester (enabled by default in the ory-hydra module) watches for these CRDs
# and creates/manages the OAuth2 client via Hydra's admin API.
# Read the OAuth2 client credentials after Hydra Maester populates the secret.
# This lets the Materialize system parameters reference the auto-generated client_id.
data "kubernetes_secret_v1" "oauth2_client" {
  metadata {
    name      = "materialize-oauth2-client"
    namespace = "ory"
  }

  depends_on = [kubectl_manifest.materialize_oauth2_client]
}

resource "kubectl_manifest" "materialize_oauth2_client" {
  yaml_body = yamlencode({
    apiVersion = "hydra.ory.sh/v1alpha1"
    kind       = "OAuth2Client"
    metadata = {
      name      = "materialize"
      namespace = module.ory_hydra.namespace
    }
    spec = {
      clientName = "Materialize"
      grantTypes = [
        "authorization_code",
        "refresh_token",
      ]
      responseTypes = ["code", "id_token"]
      scope         = "openid profile email offline"
      audience      = ["materialize"]
      redirectUris  = ["https://${var.materialize_console_hostname}/auth/callback"]
      # Public client (SPA) — no client secret; the Materialize console uses PKCE
      # to exchange the authorization code for tokens.
      secretName              = "materialize-oauth2-client"
      tokenEndpointAuthMethod = "none"
    }
  })

  depends_on = [module.ory_hydra]
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

  # External URLs for Ory components. These are what the browser (and Materialize, for
  # issuer matching) sees. Customer-provided hostnames resolve to the LoadBalancer IPs
  # and are terminated by TLS certs issued by cert-manager.
  hydra_external_url  = "https://${var.ory_hydra_hostname}/"
  ui_external_url     = "https://${var.ory_ui_hostname}"
  kratos_external_url = "https://${var.ory_kratos_hostname}"

  # Parent domain shared by all Ory hostnames (the part after the first label).
  # Used as the cookie domain so flow/session cookies are shared across
  # sibling subdomains (Kratos, selfservice UI, Hydra).
  cookie_parent_domain = join(".", slice(split(".", var.ory_kratos_hostname), 1, length(split(".", var.ory_kratos_hostname))))

  # cert-manager ClusterIssuer used for browser-facing TLS certs (Materialize
  # console/balancerd, Hydra, Kratos, selfservice UI). Defaults to the built-in
  # self-signed issuer; override via var.cert_issuer_ref to plug in a real
  # issuer (corporate CA, Let's Encrypt, etc.). See the README for a Let's
  # Encrypt + Cloudflare DNS-01 example.
  cert_issuer = var.cert_issuer_ref != null ? var.cert_issuer_ref : {
    name = module.self_signed_cluster_issuer.issuer_name
    kind = "ClusterIssuer"
  }

  # Internal cert issuer for the Materialize CR's internalCertificateSpec, which
  # has cluster.local SANs that public ACME issuers (Let's Encrypt) can't sign.
  # Always uses the self-signed cluster issuer regardless of cert_issuer_ref.
  internal_cert_issuer = {
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

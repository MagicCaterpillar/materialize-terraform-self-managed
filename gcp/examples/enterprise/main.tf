provider "google" {
  project        = var.project_id
  region         = var.region
  default_labels = var.labels
}

# Configure kubernetes provider with GKE cluster credentials
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = "https://${module.gke.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.cluster_ca_certificate)

  load_config_file = false
}

locals {

  materialize_operator_namespace = "materialize"
  materialize_instance_namespace = "materialize-environment"
  materialize_instance_name      = "main"

  # Common node scheduling configuration
  generic_node_labels = {
    "workload" = "generic"
  }

  materialize_node_labels = {
    "workload" = "materialize-instance"
  }

  materialize_node_taints = [
    {
      key    = "materialize.cloud/workload"
      value  = "materialize-instance"
      effect = "NO_SCHEDULE"
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


  subnets = [
    {
      name           = "${var.name_prefix}-subnet"
      cidr           = "192.168.0.0/20"
      region         = var.region
      private_access = true
      secondary_ranges = [
        {
          range_name    = "pods"
          ip_cidr_range = "192.168.64.0/18"
        },
        {
          range_name    = "services"
          ip_cidr_range = "192.168.128.0/20"
        }
      ]
    }
  ]

  gke_config = {
    machine_type = "n2-highmem-8"
    disk_size_gb = 100
    min_nodes    = 2
    max_nodes    = 5
  }

  database_config = {
    tier      = "db-custom-2-4096"
    database  = { name = "materialize", charset = "UTF8", collation = "en_US.UTF8" }
    user_name = "materialize"
  }

  # Ory database configuration (separate Cloud SQL instance)
  ory_database_config = {
    tier      = "db-f1-micro"
    user_name = "oryadmin"
  }

  local_ssd_count = 1
  swap_enabled    = true

  database_statement_timeout = "15min"

  metadata_backend_url = format(
    "postgres://%s:%s@%s/%s?sslmode=require&options=-c%%20statement_timeout%%3D%s",
    module.database.users[0].name,
    urlencode(module.database.users[0].password),
    module.database.private_ip,
    local.database_config.database.name,
    local.database_statement_timeout
  )


  encoded_endpoint = urlencode("https://storage.googleapis.com")
  encoded_secret   = urlencode(module.storage.hmac_secret)

  persist_backend_url = format(
    "s3://%s:%s@%s/materialize?endpoint=%s&region=%s",
    module.storage.hmac_access_id,
    local.encoded_secret,
    module.storage.bucket_name,
    local.encoded_endpoint,
    var.region
  )

  kubeconfig_data = jsonencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = module.gke.cluster_name
      cluster = {
        certificate-authority-data = module.gke.cluster_ca_certificate
        server                     = "https://${module.gke.cluster_endpoint}"
      }
    }]
    contexts = [{
      name = module.gke.cluster_name
      context = {
        cluster = module.gke.cluster_name
        user    = module.gke.cluster_name
      }
    }]
    current-context = module.gke.cluster_name
    users = [{
      name = module.gke.cluster_name
      user = {
        token : data.google_client_config.default.access_token
      }
    }]
  })
  storage_class = "standard-rwo" # default storage class in gcp

  # Ory database DSNs
  ory_kratos_dsn = format(
    "postgres://%s:%s@%s/%s?sslmode=disable",
    module.ory_database.users[0].name,
    urlencode(module.ory_database.users[0].password),
    module.ory_database.private_ip,
    "kratos"
  )

  ory_hydra_dsn = format(
    "postgres://%s:%s@%s/%s?sslmode=disable",
    module.ory_database.users[0].name,
    urlencode(module.ory_database.users[0].password),
    module.ory_database.private_ip,
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
  # console/balancerd, Hydra, Kratos, selfservice UI). Resolution order:
  #   1. var.cert_issuer_ref if set (bring-your-own corporate CA, etc.)
  #   2. Let's Encrypt issuer when var.enable_letsencrypt = true
  #   3. Built-in self-signed issuer (the demo default)
  cert_issuer = var.cert_issuer_ref != null ? var.cert_issuer_ref : (
    var.enable_letsencrypt
    ? module.letsencrypt_cluster_issuer[0].issuer_ref
    : {
      name = module.self_signed_cluster_issuer[0].issuer_name
      kind = "ClusterIssuer"
    }
  )

  # Internal cert issuer for the Materialize CR's internalCertificateSpec, which
  # has cluster.local SANs that public ACME issuers (Let's Encrypt) can't sign.
  # Always uses the self-signed cluster issuer, except when the customer brings
  # their own ClusterIssuer (which is then assumed to handle cluster.local too).
  internal_cert_issuer = var.cert_issuer_ref != null ? var.cert_issuer_ref : {
    name = module.self_signed_cluster_issuer[0].issuer_name
    kind = "ClusterIssuer"
  }

  # GCP annotations for the LoadBalancer services fronting Ory (Hydra public,
  # Kratos public, selfservice UI) and the Materialize console. Internal LBs use
  # GKE's Internal TCP/UDP Network LB; public LBs use the default external NLB.
  ory_lb_annotations = var.internal_load_balancer ? {
    "networking.gke.io/load-balancer-type" = "Internal"
  } : {}
}

# Configure networking infrastructure including VPC, subnets, and CIDR blocks
module "networking" {
  source = "../../modules/networking"

  project_id = var.project_id
  region     = var.region
  prefix     = var.name_prefix
  subnets    = local.subnets
  labels     = var.labels
}

# Set up Google Kubernetes Engine (GKE) cluster
module "gke" {
  source = "../../modules/gke"

  depends_on = [module.networking]

  project_id   = var.project_id
  region       = var.region
  prefix       = var.name_prefix
  network_name = module.networking.network_name
  # we only have one subnet, so we can use the first one
  # if multiple subnets are created, we need to use the specific subnet name here
  subnet_name                       = module.networking.subnets_names[0]
  namespace                         = local.materialize_operator_namespace
  k8s_apiserver_authorized_networks = var.k8s_apiserver_authorized_networks
  labels                            = var.labels
}

# Create and configure generic node pool for all workloads except Materialize
module "generic_nodepool" {
  source     = "../../modules/nodepool"
  depends_on = [module.gke]

  prefix                = "${var.name_prefix}-generic"
  region                = var.region
  enable_private_nodes  = true
  cluster_name          = module.gke.cluster_name
  project_id            = var.project_id
  min_nodes             = 2
  max_nodes             = 5
  machine_type          = "e2-standard-8"
  disk_size_gb          = 50
  service_account_email = module.gke.service_account_email
  labels                = local.generic_node_labels
  swap_enabled          = false
  local_ssd_count       = 0
}

# Create and configure Materialize-dedicated node pool with taints
module "materialize_nodepool" {
  source     = "../../modules/nodepool"
  depends_on = [module.gke]

  prefix                = "${var.name_prefix}-mz"
  region                = var.region
  enable_private_nodes  = true
  cluster_name          = module.gke.cluster_name
  project_id            = var.project_id
  min_nodes             = local.gke_config.min_nodes
  max_nodes             = local.gke_config.max_nodes
  machine_type          = local.gke_config.machine_type
  disk_size_gb          = local.gke_config.disk_size_gb
  service_account_email = module.gke.service_account_email
  labels                = merge(var.labels, local.materialize_node_labels)
  # Materialize-specific taint to isolate workloads
  node_taints = local.materialize_node_taints

  swap_enabled    = local.swap_enabled
  local_ssd_count = local.local_ssd_count
}

# Deploy custom CoreDNS with TTL 0 (GKE's kube-dns doesn't support disabling caching)
module "coredns" {
  source                                      = "../../../kubernetes/modules/coredns"
  create_coredns_service_account              = true
  node_selector                               = local.generic_node_labels
  kubeconfig_data                             = local.kubeconfig_data
  coredns_deployment_to_scale_down            = "kube-dns"
  coredns_autoscaler_deployment_to_scale_down = "kube-dns-autoscaler"
  depends_on = [
    module.gke,
    module.generic_nodepool,
  ]
}

resource "random_password" "external_login_password_mz_system" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Set up PostgreSQL database instance for Materialize metadata storage
module "database" {
  source     = "../../modules/database"
  depends_on = [module.networking]

  databases = [local.database_config.database]
  # We don't provide password, so random password is generated
  users = [{ name = local.database_config.user_name }]

  project_id = var.project_id
  region     = var.region
  prefix     = var.name_prefix
  network_id = module.networking.network_id

  tier = local.database_config.tier

  labels = var.labels
}

# Separate Cloud SQL instance for Ory (Kratos + Hydra)
module "ory_database" {
  source     = "../../modules/database"
  depends_on = [module.networking]

  databases = [
    { name = "kratos", charset = "UTF8", collation = "en_US.UTF8" },
    { name = "hydra", charset = "UTF8", collation = "en_US.UTF8" }
  ]
  users = [{ name = local.ory_database_config.user_name }]

  project_id = var.project_id
  region     = var.region
  prefix     = "${var.name_prefix}-ory"
  network_id = module.networking.network_id

  tier = local.ory_database_config.tier

  labels = var.labels
}

# Create Google Cloud Storage bucket for Materialize persistent data storage
module "storage" {
  source = "../../modules/storage"

  project_id      = var.project_id
  region          = var.region
  prefix          = var.name_prefix
  service_account = module.gke.workload_identity_sa_email
  versioning      = false
  version_ttl     = 7

  labels = var.labels
}

# Install cert-manager for SSL certificate management and create cluster issuer
module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  node_selector = local.generic_node_labels

  depends_on = [
    module.gke,
    module.generic_nodepool,
    module.coredns,
  ]
}

# Issuer modes:
#   - var.cert_issuer_ref set       → no module created here, customer brings their own
#   - var.enable_letsencrypt = true → letsencrypt_cluster_issuer for external certs +
#                                     self_signed_cluster_issuer for internal mTLS
#                                     (LE cannot sign *.cluster.local)
#   - otherwise (demo default)      → self_signed_cluster_issuer for everything
module "self_signed_cluster_issuer" {
  count  = var.cert_issuer_ref == null ? 1 : 0
  source = "../../../kubernetes/modules/self-signed-cluster-issuer"

  name_prefix = var.name_prefix

  depends_on = [
    module.cert_manager,
  ]
}

module "letsencrypt_cluster_issuer" {
  count  = var.cert_issuer_ref == null && var.enable_letsencrypt ? 1 : 0
  source = "../../../kubernetes/modules/letsencrypt-cluster-issuer"

  name             = "${var.name_prefix}-letsencrypt-${var.letsencrypt_acme_environment}"
  email            = var.letsencrypt_email
  acme_environment = var.letsencrypt_acme_environment
  dns_provider     = var.letsencrypt_dns_provider
  dns_zones        = var.letsencrypt_dns_zones

  cloudflare_api_token = var.cloudflare_api_token

  depends_on = [
    module.cert_manager,
  ]
}

# Install Materialize Kubernetes operator for managing Materialize instances
module "operator" {
  source = "../../modules/operator"

  name_prefix = var.name_prefix
  region      = var.region

  # ARM tolerations and node selector for all operator workloads on GCP
  instance_pod_tolerations = local.materialize_tolerations
  instance_node_selector   = local.materialize_node_labels

  # node selector for operator and metrics-server workloads
  operator_node_selector = local.generic_node_labels


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
  enable_network_policies = true
  depends_on = [
    module.gke,
    module.generic_nodepool,
    module.database,
    module.storage,
    module.coredns,
  ]
}

module "prometheus" {
  count  = var.enable_observability ? 1 : 0
  source = "../../../kubernetes/modules/prometheus"

  namespace        = "monitoring"
  create_namespace = false # operator creates the "monitoring" namespace
  node_selector    = local.generic_node_labels
  storage_class    = local.storage_class
  depends_on = [
    module.operator,
    module.gke,
    module.generic_nodepool,
    module.coredns,
  ]
}

module "grafana" {
  count  = var.enable_observability ? 1 : 0
  source = "../../../kubernetes/modules/grafana"

  namespace     = "monitoring"
  storage_class = local.storage_class
  # operator creates the "monitoring" namespace
  create_namespace = false
  prometheus_url   = module.prometheus[0].prometheus_url
  node_selector    = local.generic_node_labels

  depends_on = [
    module.prometheus,
  ]
}

# Deploy Materialize instance with configured backend connections
module "materialize_instance" {
  source                  = "../../../kubernetes/modules/materialize-instance"
  instance_name           = local.materialize_instance_name
  instance_namespace      = local.materialize_instance_namespace
  metadata_backend_url    = local.metadata_backend_url
  persist_backend_url     = local.persist_backend_url
  enable_network_policies = true

  # Use OIDC authentication via Ory Hydra. The external_login_password is still required
  # as a fallback for the mz_system admin user.
  external_login_password_mz_system = random_password.external_login_password_mz_system.result
  authenticator_kind                = "Oidc"

  # GCP workload identity annotation for service account
  # TODO: this needs a fix in Environmentd Client. KSA based access to storage doesn't work end to end
  service_account_annotations = {
    "iam.gke.io/gcp-service-account" = module.gke.workload_identity_sa_email
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
    module.gke,
    module.database,
    module.storage,
    module.networking,
    module.self_signed_cluster_issuer,
    module.letsencrypt_cluster_issuer,
    module.operator,
    module.materialize_nodepool,
    module.coredns,
    module.ory_hydra,
    kubectl_manifest.materialize_oauth2_client,
  ]
}

# Configure load balancers for external access to Materialize services
module "load_balancers" {
  source = "../../modules/load_balancers"

  project_id                 = var.project_id
  network_name               = module.networking.network_name
  prefix                     = var.name_prefix
  node_service_account_email = module.gke.service_account_email
  internal                   = var.internal_load_balancer
  ingress_cidr_blocks        = var.ingress_cidr_blocks
  instance_name              = local.materialize_instance_name
  namespace                  = local.materialize_instance_namespace
  resource_id                = module.materialize_instance.instance_resource_id

  depends_on = [
    module.materialize_instance,
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

  depends_on = [module.gke]
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
    module.gke,
    module.ory_database,
    module.generic_nodepool,
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
    module.gke,
    module.ory_database,
    module.ory_kratos,
    module.generic_nodepool,
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
      # The external hostname covers browser traffic. The cluster-internal SAN is
      # only included when the issuer is private (self-signed) — public ACME
      # issuers (Let's Encrypt) reject .cluster.local because it isn't a valid
      # public suffix. In LE mode, in-cluster clients reach Hydra by its public
      # hostname (hairpin NAT through the LB) and TLS still validates.
      dnsNames = concat(
        [var.ory_hydra_hostname],
        var.enable_letsencrypt ? [] : ["hydra-public.ory.svc.cluster.local"],
      )
      issuerRef = local.cert_issuer
    }
  })

  depends_on = [
    module.self_signed_cluster_issuer,
    module.letsencrypt_cluster_issuer,
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
      # The external hostname covers browser traffic. The cluster-internal SAN is
      # only included when the issuer is private (self-signed) — public ACME
      # issuers (Let's Encrypt) reject .cluster.local because it isn't a valid
      # public suffix. In LE mode, the selfservice UI reaches Kratos by its public
      # hostname (hairpin NAT through the LB) and TLS still validates.
      dnsNames = concat(
        [var.ory_kratos_hostname],
        var.enable_letsencrypt ? [] : ["kratos-public.ory.svc.cluster.local"],
      )
      issuerRef = local.cert_issuer
    }
  })

  depends_on = [
    module.self_signed_cluster_issuer,
    module.letsencrypt_cluster_issuer,
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
    module.letsencrypt_cluster_issuer,
    kubernetes_namespace.ory,
  ]
}

# Login + consent UI that sits between Hydra and Kratos.
# Without this, Hydra has no way to authenticate users or collect consent.
module "ory_selfservice_ui" {
  source = "../../../kubernetes/modules/ory-selfservice-ui"

  namespace = "ory"
  # Server-side calls from the UI pod to Kratos's public API. With a private
  # issuer we can use the cluster service URL (cert SAN covers cluster.local).
  # With LE the cert only has the external hostname, so route through it
  # (resolves to the LB IP via public DNS and hairpins back into the cluster).
  kratos_public_url = var.enable_letsencrypt ? local.kratos_external_url : module.ory_kratos.public_url
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
    type = "LoadBalancer"

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

  depends_on = [module.ory_kratos]
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
    type = "LoadBalancer"

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

  depends_on = [module.ory_hydra]
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
    type = "LoadBalancer"

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

  depends_on = [module.materialize_instance]
}

# External LoadBalancer for the selfservice UI (browser-facing login/consent).
resource "kubernetes_service_v1" "ui_lb" {
  metadata {
    name        = "ory-selfservice-ui-lb"
    namespace   = "ory"
    annotations = local.ory_lb_annotations
  }

  spec {
    type = "LoadBalancer"

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

  depends_on = [module.ory_selfservice_ui]
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

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
    tier                    = "db-custom-2-4096"
    database                = { name = "materialize", charset = "UTF8", collation = "en_US.UTF8" }
    user_name               = "materialize"
    db_version              = "POSTGRES_17"
    backup_retained_backups = 35
  }

  # Ory database configuration (separate Cloud SQL instance)
  ory_database_config = {
    tier                    = "db-f1-micro"
    user_name               = "oryadmin"
    db_version              = "POSTGRES_17"
    backup_retained_backups = 35
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

  ory_namespace = "ory"

  # External URLs for Ory components. These are what the browser (and Materialize,
  # for issuer matching) sees. Customer-provided hostnames resolve to the
  # LoadBalancer IPs and are terminated by TLS certs issued by cert-manager.
  hydra_external_url  = "https://${var.ory_hydra_hostname}/"
  ui_external_url     = "https://${var.ory_ui_hostname}"
  kratos_external_url = "https://${var.ory_kratos_hostname}"

  # Parent domain shared by all Ory hostnames. Used as the cookie domain so
  # flow/session cookies work across sibling subdomains (Kratos, UI, Hydra).
  cookie_parent_domain = regex("^[^.]+\\.(.+)$", var.ory_kratos_hostname)[0]

  # cert-manager ClusterIssuer for browser-facing TLS. Defaults to the built-in
  # self-signed issuer; override via var.cert_issuer_ref to plug in a real one.
  cert_issuer = var.cert_issuer_ref != null ? var.cert_issuer_ref : {
    name = module.self_signed_cluster_issuer.issuer_name
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
  source = "../../modules/nodepool"

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
  source = "../../modules/nodepool"

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
  cluster_identifier                          = module.gke.cluster_name
  coredns_deployment_to_scale_down            = "kube-dns"
  coredns_autoscaler_deployment_to_scale_down = "kube-dns-autoscaler"
  depends_on                                  = [module.generic_nodepool]
}

resource "random_password" "external_login_password_mz_system" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Set up PostgreSQL database instance for Materialize metadata storage
module "database" {
  source = "../../modules/database"

  databases = [local.database_config.database]
  # We don't provide password, so random password is generated
  users = [{ name = local.database_config.user_name }]

  project_id = var.project_id
  region     = var.region
  prefix     = var.name_prefix
  network_id = module.networking.network_id

  tier                    = local.database_config.tier
  db_version              = local.database_config.db_version
  backup_retained_backups = local.database_config.backup_retained_backups

  labels = var.labels
}

# Separate Cloud SQL instance for Ory (Kratos + Hydra)
module "ory_database" {
  source = "../../modules/database"

  databases = [
    { name = "kratos", charset = "UTF8", collation = "en_US.UTF8" },
    { name = "hydra", charset = "UTF8", collation = "en_US.UTF8" }
  ]
  users = [{ name = local.ory_database_config.user_name }]

  project_id = var.project_id
  region     = var.region
  prefix     = "${var.name_prefix}-ory"
  network_id = module.networking.network_id

  tier                    = local.ory_database_config.tier
  db_version              = local.ory_database_config.db_version
  backup_retained_backups = local.ory_database_config.backup_retained_backups

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
    oidc_issuer               = local.hydra_external_url
    oidc_audience             = jsonencode([data.kubernetes_secret_v1.oauth2_client.data["CLIENT_ID"]])
    oidc_authentication_claim = "email"
    console_oidc_client_id    = data.kubernetes_secret_v1.oauth2_client.data["CLIENT_ID"]
    console_oidc_scopes       = "openid email"
  }

  depends_on = [
    module.operator,
    module.materialize_nodepool,
    module.coredns,
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
}

# -----------------------------------------------------------------------------
# Ory: Identity & OAuth2 (Kratos + Hydra)
# -----------------------------------------------------------------------------

resource "kubernetes_namespace" "ory" {
  metadata {
    name = local.ory_namespace
  }

  depends_on = [module.gke]
}

# SECURITY: file() embeds the GCP service-account key into Terraform state
# in plaintext. Treat state as sensitive. See README "Limitations".
# TODO: Replace with the Materialize-hosted OEL mirror (license-key JWT auth)
# once it ships, so a customer no longer needs a shared GCP service-account key.
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

  namespace        = local.ory_namespace
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

  # Optional upstream OIDC providers (Okta, Entra, Auth0, Google, etc.) exposed
  # as social sign-in buttons on the selfservice UI. Defaults to [] (password-
  # only login). Each entry's redirect URI is registered at the upstream IdP as
  # https://<ory_kratos_hostname>/self-service/methods/oidc/callback/<id>.
  upstream_oidc_providers = var.upstream_oidc_providers

  depends_on = [
    module.coredns,
    kubernetes_secret.ory_oel_registry,
    kubernetes_namespace.ory,
    kubectl_manifest.ory_certificate["kratos-tls"],
  ]
}

module "ory_hydra" {
  source = "../../../kubernetes/modules/ory-hydra"

  namespace        = local.ory_namespace
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
    module.ory_kratos,
    module.coredns,
    kubernetes_secret.ory_oel_registry,
    kubectl_manifest.ory_certificate["hydra-tls"],
  ]
}

# TLS certificates for Hydra, Kratos and the selfservice UI. The optional
# *.cluster.local SAN is dropped when the customer brings their own
# (potentially public ACME) issuer that can't sign single-label cluster
# names; in that case in-cluster callers route via the public hostname
# (hairpin NAT through the LB; TLS still validates).
resource "kubectl_manifest" "ory_certificate" {
  for_each = {
    hydra-tls              = { hostname = var.ory_hydra_hostname, cluster_svc = "hydra-public.ory.svc.cluster.local" }
    kratos-tls             = { hostname = var.ory_kratos_hostname, cluster_svc = "kratos-public.ory.svc.cluster.local" }
    ory-selfservice-ui-tls = { hostname = var.ory_ui_hostname, cluster_svc = null }
  }

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = each.key
      namespace = local.ory_namespace
    }
    spec = {
      secretName = each.key
      dnsNames = concat(
        [each.value.hostname],
        var.cert_issuer_ref == null && each.value.cluster_svc != null ? [each.value.cluster_svc] : [],
      )
      issuerRef = local.cert_issuer
    }
  })

  depends_on = [kubernetes_namespace.ory]
}

# Login + consent UI that sits between Hydra and Kratos.
# Without this, Hydra has no way to authenticate users or collect consent.
module "ory_selfservice_ui" {
  source = "../../../kubernetes/modules/ory-selfservice-ui"

  namespace = local.ory_namespace
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

  # Only needed when Kratos/Hydra are served by the in-cluster self-signed CA.
  trust_mounted_ca_cert = var.cert_issuer_ref == null

  node_selector = local.generic_node_labels

  depends_on = [
    module.coredns,
    kubectl_manifest.ory_certificate["ory-selfservice-ui-tls"],
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
            "kubernetes.io/metadata.name" = local.ory_namespace
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
    namespace = local.ory_namespace
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
            "kubernetes.io/metadata.name" = local.ory_namespace
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

# External LoadBalancers for Kratos public (4433), Hydra public (4444), and
# the selfservice UI. Admin ports (Kratos 4434, Hydra 4445) are intentionally
# not exposed; they stay cluster-internal.
resource "kubernetes_service_v1" "ory_lb" {
  for_each = {
    kratos-public-lb = {
      app_name     = "kratos"
      app_instance = "kratos"
      target_port  = 4433
    }
    hydra-public-lb = {
      app_name     = "hydra"
      app_instance = "hydra"
      target_port  = 4444
    }
    ory-selfservice-ui-lb = {
      app_name     = "kratos-selfservice-ui-node"
      app_instance = module.ory_selfservice_ui.service_name
      target_port  = module.ory_selfservice_ui.port
    }
  }

  metadata {
    name        = each.key
    namespace   = local.ory_namespace
    annotations = local.ory_lb_annotations
  }

  spec {
    type = "LoadBalancer"
    selector = {
      "app.kubernetes.io/name"     = each.value.app_name
      "app.kubernetes.io/instance" = each.value.app_instance
    }
    port {
      name        = "https"
      port        = 443
      target_port = each.value.target_port
      protocol    = "TCP"
    }
  }

  depends_on = [
    module.ory_kratos,
    module.ory_hydra,
  ]
}

# External LoadBalancer for the Materialize console on 443 (the console
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
}

# Register an OAuth2 client in Hydra for Materialize.
# Hydra Maester (enabled by default in the ory-hydra module) watches for these CRDs
# and creates/manages the OAuth2 client via Hydra's admin API.
# Read the OAuth2 client credentials after Hydra Maester populates the secret.
# This lets the Materialize system parameters reference the auto-generated client_id.
data "kubernetes_secret_v1" "oauth2_client" {
  metadata {
    name      = "materialize-oauth2-client"
    namespace = local.ory_namespace
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
}

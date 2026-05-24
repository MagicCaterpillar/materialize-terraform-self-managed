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

  # cert-manager ClusterIssuer for browser-facing TLS. Defaults to the built-in
  # self-signed issuer; override via var.cert_issuer_ref to plug in a real one.
  cert_issuer = var.cert_issuer_ref != null ? var.cert_issuer_ref : {
    name = module.self_signed_cluster_issuer.issuer_name
    kind = "ClusterIssuer"
  }
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
    oidc_issuer               = module.ory.hydra_external_url
    oidc_audience             = jsonencode([module.ory.oauth2_client_id])
    oidc_authentication_claim = "email"
    console_oidc_client_id    = module.ory.oauth2_client_id
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

  oel_registry    = var.ory_oel_registry
  oel_image_tag   = var.ory_oel_image_tag
  license_key_jwt = var.license_key

  cert_issuer_ref                 = local.cert_issuer
  cert_issuer_signs_cluster_local = var.cert_issuer_ref == null

  # Materialize integration: OAuth2 client CRD, network policies, console LB.
  materialize_namespace            = local.materialize_instance_namespace
  materialize_instance_name        = local.materialize_instance_name
  materialize_instance_resource_id = module.materialize_instance.instance_resource_id
  materialize_console_fqdn         = var.materialize_console_hostname

  # GKE Internal TCP/UDP Network LB when var.internal_load_balancer = true,
  # external NLB otherwise.
  lb_annotations = var.internal_load_balancer ? {
    "networking.gke.io/load-balancer-type" = "Internal"
  } : {}

  node_selector = local.generic_node_labels

  # Optional upstream OIDC providers (Okta, Entra, Auth0, Google, etc.) exposed
  # as social sign-in buttons on the selfservice UI.
  upstream_oidc_providers = var.upstream_oidc_providers

  depends_on = [
    module.coredns,
  ]
}

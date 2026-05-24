provider "azurerm" {
  # Set the Azure subscription ID here or use the AZURE_SUBSCRIPTION_ID environment variable
  subscription_id = var.subscription_id

  # Conservative defaults for an enterprise stack. See README "Limitations".
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "kubernetes" {
  host                   = module.aks.cluster_endpoint
  client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
  client_key             = base64decode(module.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = module.aks.cluster_endpoint
    client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
    client_key             = base64decode(module.aks.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = module.aks.cluster_endpoint
  client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
  client_key             = base64decode(module.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)

  load_config_file = false
}


locals {
  vnet_config = {
    address_space                      = "20.0.0.0/16"
    aks_subnet_cidr                    = "20.0.0.0/20"
    postgres_subnet_cidr               = "20.0.16.0/24"
    enable_api_server_vnet_integration = true
    api_server_subnet_cidr             = "20.0.32.0/27" # keeping atleast 32 IPs reserved for API server and related services used in delegation might reduce it later.
  }

  aks_config = {
    kubernetes_version         = "1.33"
    service_cidr               = "20.1.0.0/16"
    enable_azure_monitor       = false
    log_analytics_workspace_id = null
  }

  node_pool_config = {
    vm_size              = "Standard_E4pds_v6"
    auto_scaling_enabled = true
    min_nodes            = 2
    max_nodes            = 5
    node_count           = null
    disk_size_gb         = 100
    swap_enabled         = true
  }

  database_config = {
    sku_name                      = "GP_Standard_D2s_v3"
    postgres_version              = "18"
    storage_mb                    = 32768
    backup_retention_days         = 35
    administrator_login           = "materialize"
    administrator_password        = null # Will generate random password
    database_name                 = "materialize"
    public_network_access_enabled = false
  }

  # Ory database configuration (separate Postgres instance)
  ory_database_config = {
    sku_name                      = "B_Standard_B1ms"
    postgres_version              = "18"
    storage_mb                    = 32768
    backup_retention_days         = 35
    administrator_login           = "oryadmin"
    administrator_password        = null # Will generate random password
    public_network_access_enabled = false
  }

  storage_container_name = "materialize"

  database_statement_timeout = "15min"

  metadata_backend_url = format(
    "postgres://%s:%s@%s/%s?sslmode=require&options=-c%%20statement_timeout%%3D%s",
    module.database.administrator_login,
    urlencode(module.database.administrator_password),
    module.database.server_fqdn,
    local.database_config.database_name,
    local.database_statement_timeout
  )

  persist_backend_url = format(
    "%s%s",
    module.storage.primary_blob_endpoint,
    module.storage.container_name,
  )

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

  # https://learn.microsoft.com/en-us/azure/aks/concepts-storage#storage-classes
  storage_class = "managed-csi"

  # Ory database DSNs
  ory_kratos_dsn = format(
    "postgres://%s:%s@%s/%s?sslmode=require",
    module.ory_database.administrator_login,
    urlencode(module.ory_database.administrator_password),
    module.ory_database.server_fqdn,
    "kratos"
  )

  ory_hydra_dsn = format(
    "postgres://%s:%s@%s/%s?sslmode=require",
    module.ory_database.administrator_login,
    urlencode(module.ory_database.administrator_password),
    module.ory_database.server_fqdn,
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


resource "azurerm_resource_group" "materialize" {
  name     = var.resource_group_name
  location = var.location
}


module "networking" {
  source = "../../modules/networking"

  resource_group_name                = azurerm_resource_group.materialize.name
  location                           = var.location
  prefix                             = var.name_prefix
  vnet_address_space                 = local.vnet_config.address_space
  aks_subnet_cidr                    = local.vnet_config.aks_subnet_cidr
  postgres_subnet_cidr               = local.vnet_config.postgres_subnet_cidr
  enable_api_server_vnet_integration = local.vnet_config.enable_api_server_vnet_integration
  api_server_subnet_cidr             = local.vnet_config.api_server_subnet_cidr

  tags = var.tags
}

# AKS Cluster with Default Node Pool
module "aks" {
  source = "../../modules/aks"

  resource_group_name = azurerm_resource_group.materialize.name
  kubernetes_version  = local.aks_config.kubernetes_version
  service_cidr        = local.aks_config.service_cidr
  location            = var.location
  prefix              = var.name_prefix
  vnet_name           = module.networking.vnet_name
  subnet_name         = module.networking.aks_subnet_name
  subnet_id           = module.networking.aks_subnet_id

  enable_api_server_vnet_integration = local.vnet_config.enable_api_server_vnet_integration
  k8s_apiserver_authorized_networks  = concat(var.k8s_apiserver_authorized_networks, ["${module.networking.nat_gateway_public_ip}/32"])
  api_server_subnet_id               = module.networking.api_server_subnet_id

  # Default node pool with autoscaling (runs all workloads except Materialize)
  default_node_pool_vm_size             = "Standard_D4pds_v6"
  default_node_pool_enable_auto_scaling = true
  default_node_pool_min_count           = 2
  default_node_pool_max_count           = 5
  default_node_pool_node_labels         = local.generic_node_labels

  # Optional: Enable monitoring
  enable_azure_monitor       = local.aks_config.enable_azure_monitor
  log_analytics_workspace_id = local.aks_config.log_analytics_workspace_id

  tags = var.tags
}

# Materialize-dedicated node pool with taints (via labels on Azure)
module "materialize_nodepool" {
  source = "../../modules/nodepool"

  prefix     = var.name_prefix
  cluster_id = module.aks.cluster_id
  subnet_id  = module.networking.aks_subnet_id

  # Workload-specific configuration
  autoscaling_config = {
    enabled    = local.node_pool_config.auto_scaling_enabled
    min_nodes  = local.node_pool_config.min_nodes
    max_nodes  = local.node_pool_config.max_nodes
    node_count = local.node_pool_config.node_count
  }

  vm_size      = local.node_pool_config.vm_size
  disk_size_gb = local.node_pool_config.disk_size_gb
  swap_enabled = local.node_pool_config.swap_enabled

  labels = local.materialize_node_labels

  # Materialize-specific taint to isolate workloads
  # https://github.com/Azure/AKS/issues/2934
  # Note: Once applied, these cannot be manually removed due to AKS webhook restrictions
  node_taints = local.materialize_node_taints

  tags = var.tags
}


module "database" {
  source = "../../modules/database"

  # Database configuration using new structure
  databases = [
    {
      name      = local.database_config.database_name
      charset   = "UTF8"
      collation = "en_US.utf8"
    }
  ]

  # Administrator configuration
  administrator_login = local.database_config.administrator_login

  # Infrastructure configuration
  resource_group_name = azurerm_resource_group.materialize.name
  location            = var.location
  prefix              = var.name_prefix
  subnet_id           = module.networking.postgres_subnet_id
  private_dns_zone_id = module.networking.private_dns_zone_id

  # Database server configuration
  sku_name                      = local.database_config.sku_name
  postgres_version              = local.database_config.postgres_version
  storage_mb                    = local.database_config.storage_mb
  backup_retention_days         = local.database_config.backup_retention_days
  public_network_access_enabled = local.database_config.public_network_access_enabled

  tags = var.tags
}

# Separate Postgres instance for Ory (Kratos + Hydra)
module "ory_database" {
  source = "../../modules/database"

  databases = [
    {
      name      = "kratos"
      charset   = "UTF8"
      collation = "en_US.utf8"
    },
    {
      name      = "hydra"
      charset   = "UTF8"
      collation = "en_US.utf8"
    }
  ]

  administrator_login = local.ory_database_config.administrator_login

  resource_group_name = azurerm_resource_group.materialize.name
  location            = var.location
  prefix              = "${var.name_prefix}-ory"
  subnet_id           = module.networking.postgres_subnet_id
  private_dns_zone_id = module.networking.private_dns_zone_id

  sku_name                      = local.ory_database_config.sku_name
  postgres_version              = local.ory_database_config.postgres_version
  storage_mb                    = local.ory_database_config.storage_mb
  backup_retention_days         = local.ory_database_config.backup_retention_days
  public_network_access_enabled = local.ory_database_config.public_network_access_enabled

  tags = var.tags
}

# Enable PostgreSQL extensions required by Ory Kratos migrations (pg_trgm + btree_gin for GIN indexes)
resource "azurerm_postgresql_flexible_server_configuration" "ory_extensions" {
  name      = "azure.extensions"
  server_id = module.ory_database.server_id
  value     = "btree_gin,pg_trgm,uuid-ossp"
}

module "storage" {
  source = "../../modules/storage"

  resource_group_name            = azurerm_resource_group.materialize.name
  location                       = var.location
  prefix                         = var.name_prefix
  workload_identity_principal_id = module.aks.workload_identity_principal_id
  subnets                        = [module.networking.aks_subnet_id]
  container_name                 = local.storage_container_name

  # Workload identity federation configuration
  workload_identity_id      = module.aks.workload_identity_id
  oidc_issuer_url           = module.aks.cluster_oidc_issuer_url
  service_account_namespace = local.materialize_instance_namespace
  service_account_name      = local.materialize_instance_name

  storage_account_tags = var.tags
}

resource "random_password" "external_login_password_mz_system" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Deploy custom CoreDNS with TTL 0 (AKS's coredns doesn't support disabling caching)
module "coredns" {
  source             = "../../../kubernetes/modules/coredns"
  node_selector      = local.generic_node_labels
  kubeconfig_data    = module.aks.kube_config_raw
  cluster_identifier = module.aks.cluster_name
}

module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  node_selector = local.generic_node_labels

  depends_on = [
    module.aks,
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

module "operator" {
  source = "../../modules/operator"

  name_prefix = var.name_prefix
  location    = var.location

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

  depends_on = [
    module.aks,
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
    module.aks,
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

module "materialize_instance" {
  source               = "../../../kubernetes/modules/materialize-instance"
  instance_name        = local.materialize_instance_name
  instance_namespace   = local.materialize_instance_namespace
  metadata_backend_url = local.metadata_backend_url
  persist_backend_url  = local.persist_backend_url

  # Use OIDC authentication via Ory Hydra. The external_login_password is still required
  # as a fallback for the mz_system admin user.
  authenticator_kind                = "Oidc"
  external_login_password_mz_system = random_password.external_login_password_mz_system.result

  # Azure workload identity annotations for service account
  service_account_annotations = {
    "azure.workload.identity/client-id" = module.aks.workload_identity_client_id
  }
  pod_labels = {
    "azure.workload.identity/use" = "true"
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

module "load_balancers" {
  source = "../../modules/load_balancers"

  instance_name       = local.materialize_instance_name
  namespace           = local.materialize_instance_namespace
  resource_id         = module.materialize_instance.instance_resource_id
  internal            = var.internal_load_balancer
  ingress_cidr_blocks = var.internal_load_balancer ? null : var.ingress_cidr_blocks
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

  # Azure Load Balancer annotations. Internal LB uses the AKS internal flag.
  lb_annotations = var.internal_load_balancer ? {
    "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
  } : {}

  node_selector = local.generic_node_labels

  # Optional upstream OIDC providers (Okta, Entra, Auth0, Google, etc.) exposed
  # as social sign-in buttons on the selfservice UI.
  upstream_oidc_providers = var.upstream_oidc_providers

  depends_on = [
    module.coredns,
    azurerm_postgresql_flexible_server_configuration.ory_extensions,
  ]
}

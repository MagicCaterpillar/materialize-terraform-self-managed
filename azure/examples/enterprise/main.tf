provider "azurerm" {
  # Set the Azure subscription ID here or use the AZURE_SUBSCRIPTION_ID environment variable
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
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
    postgres_version              = "15"
    storage_mb                    = 32768
    backup_retention_days         = 7
    administrator_login           = "materialize"
    administrator_password        = null # Will generate random password
    database_name                 = "materialize"
    public_network_access_enabled = false
  }

  # Ory database configuration (separate Postgres instance)
  ory_database_config = {
    sku_name                      = "B_Standard_B1ms"
    postgres_version              = "15"
    storage_mb                    = 32768
    backup_retention_days         = 7
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

  depends_on = [azurerm_resource_group.materialize]
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

  depends_on = [azurerm_resource_group.materialize]
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

  depends_on = [azurerm_resource_group.materialize]
}


module "database" {
  source = "../../modules/database"

  depends_on = [module.networking]

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

  depends_on = [module.networking]

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

  depends_on = [module.ory_database]
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

  depends_on = [azurerm_resource_group.materialize]
}

resource "random_password" "external_login_password_mz_system" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Deploy custom CoreDNS with TTL 0 (AKS's coredns doesn't support disabling caching)
module "coredns" {
  source          = "../../../kubernetes/modules/coredns"
  node_selector   = local.generic_node_labels
  kubeconfig_data = module.aks.kube_config_raw
  depends_on = [
    module.aks,
    module.networking,
  ]
}

module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  node_selector = local.generic_node_labels

  depends_on = [
    module.aks,
    module.networking,
    module.coredns,
  ]
}

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

  depends_on = [
    module.prometheus,
  ]
}

module "materialize_instance" {
  source               = "../../../kubernetes/modules/materialize-instance"
  instance_name        = local.materialize_instance_name
  instance_namespace   = local.materialize_instance_namespace
  metadata_backend_url = local.metadata_backend_url
  persist_backend_url  = local.persist_backend_url

  # The password for the external login to the Materialize instance
  authenticator_kind                = "Password"
  external_login_password_mz_system = random_password.external_login_password_mz_system.result

  # Azure workload identity annotations for service account
  service_account_annotations = {
    "azure.workload.identity/client-id" = module.aks.workload_identity_client_id
  }
  pod_labels = {
    "azure.workload.identity/use" = "true"
  }

  license_key = var.license_key

  issuer_ref = {
    name = module.self_signed_cluster_issuer.issuer_name
    kind = "ClusterIssuer"
  }

  # System parameters for the Materialize instance
  # See: https://materialize.com/docs/self-managed-deployments/configuration-system-parameters/
  system_parameters = {}

  depends_on = [
    module.aks,
    module.database,
    module.storage,
    module.networking,
    module.self_signed_cluster_issuer,
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

  depends_on = [
    module.materialize_instance,
  ]
}

# -----------------------------------------------------------------------------
# Ory: Identity & OAuth2 (Kratos + Hydra)
# -----------------------------------------------------------------------------

module "ory_kratos" {
  source = "../../../kubernetes/modules/ory-kratos"

  namespace = "ory"
  dsn       = local.ory_kratos_dsn

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
        selfservice = {
          default_browser_return_url = var.ory_issuer_url
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
    module.aks,
    module.ory_database,
    module.coredns,
    azurerm_postgresql_flexible_server_configuration.ory_extensions,
  ]
}

module "ory_hydra" {
  source = "../../../kubernetes/modules/ory-hydra"

  namespace = "ory"
  # Share the namespace already created by Kratos
  create_namespace = false

  dsn        = local.ory_hydra_dsn
  issuer_url = var.ory_issuer_url

  # Point Hydra login/consent flows to Kratos
  login_url   = "${module.ory_kratos.public_url}/self-service/login/browser"
  consent_url = "${module.ory_kratos.public_url}/self-service/login/browser"
  logout_url  = "${module.ory_kratos.public_url}/self-service/logout/browser"

  node_selector = local.generic_node_labels

  depends_on = [
    module.aks,
    module.ory_database,
    module.ory_kratos,
    module.coredns,
    azurerm_postgresql_flexible_server_configuration.ory_extensions,
  ]
}

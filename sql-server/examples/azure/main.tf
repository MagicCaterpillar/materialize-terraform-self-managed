# ---------------------------------------------------------------------------
# Azure provider
# ---------------------------------------------------------------------------

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

# ---------------------------------------------------------------------------
# Resolve target AKS cluster credentials
#
# Set aks_cluster_name + resource_group_name to the cluster where SQL Server
# should be deployed.  This can be the same cluster as Materialize (share the
# kube_config outputs from azure/examples/simple) or a separate cluster.
# ---------------------------------------------------------------------------

data "azurerm_kubernetes_cluster" "target" {
  name                = var.aks_cluster_name
  resource_group_name = var.resource_group_name
}

locals {
  sql_server_node_selector = merge(
    var.node_selector,
    var.force_amd64_scheduling ? { "kubernetes.io/arch" = "amd64" } : {},
    var.create_amd64_node_pool ? { "agentpool" = var.amd64_node_pool_name } : {}
  )
}

resource "azurerm_kubernetes_cluster_node_pool" "sql_amd64" {
  count = var.create_amd64_node_pool ? 1 : 0

  name                  = var.amd64_node_pool_name
  kubernetes_cluster_id = data.azurerm_kubernetes_cluster.target.id
  vm_size               = var.amd64_node_pool_vm_size
  mode                  = "User"
  os_type               = "Linux"
  vnet_subnet_id        = var.amd64_node_pool_vnet_subnet_id

  auto_scaling_enabled = var.amd64_node_pool_enable_auto_scaling
  node_count           = var.amd64_node_pool_enable_auto_scaling ? null : var.amd64_node_pool_node_count
  min_count            = var.amd64_node_pool_enable_auto_scaling ? var.amd64_node_pool_min_count : null
  max_count            = var.amd64_node_pool_enable_auto_scaling ? var.amd64_node_pool_max_count : null

  tags = var.node_pool_tags

  lifecycle {
    ignore_changes = [upgrade_settings]
  }
}

# ---------------------------------------------------------------------------
# Kubernetes provider – authenticates using the AKS cluster credentials.
#
# Note: for AAD-integrated clusters (Azure AD Workload Identity or managed
# AAD), the kube_config client_certificate may be empty.  In that case,
# authenticate via kubeconfig file by replacing the provider block with:
#
#   provider "kubernetes" {
#     config_path    = "~/.kube/config"
#     config_context = "<context-name>"
#   }
# ---------------------------------------------------------------------------

provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.target.kube_config[0].host
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.target.kube_config[0].client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.target.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.target.kube_config[0].cluster_ca_certificate)
}

# ---------------------------------------------------------------------------
# SQL Server module
# ---------------------------------------------------------------------------

module "sql_server" {
  source = "../../modules/sql-server"

  # Identity & image
  namespace        = var.namespace
  name_prefix      = var.name_prefix
  image_tag        = var.image_tag
  sa_password      = var.sa_password
  sql_server_pid   = var.sql_server_pid
  enable_sql_agent = var.enable_sql_agent

  # Performance – CPU
  cpu_request = var.cpu_request
  cpu_limit   = var.cpu_limit

  # Performance – Memory
  memory_request       = var.memory_request
  memory_limit         = var.memory_limit
  max_server_memory_mb = var.max_server_memory_mb

  # Storage
  data_storage_size  = var.data_storage_size
  storage_class_name = var.storage_class_name

  # Scheduling
  node_selector = local.sql_server_node_selector
  tolerations   = var.tolerations

  # Networking
  service_type        = var.service_type
  service_annotations = var.service_annotations

  depends_on = [azurerm_kubernetes_cluster_node_pool.sql_amd64]
}

resource "kubernetes_network_policy" "materialize_to_sql_server" {
  count = var.create_materialize_sql_egress_policy ? 1 : 0

  metadata {
    name      = "allow-egress-to-sql-server"
    namespace = var.materialize_namespace
  }

  spec {
    pod_selector {}

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.namespace
          }
        }

        pod_selector {
          match_labels = {
            "app.kubernetes.io/name"     = "mssql"
            "app.kubernetes.io/instance" = var.name_prefix
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = 1433
      }
    }

    policy_types = ["Egress"]
  }

  depends_on = [module.sql_server]
}

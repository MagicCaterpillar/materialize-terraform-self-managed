# ---------------------------------------------------------------------------
# Azure / AKS targeting
# ---------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID containing the target AKS cluster."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group containing the target AKS cluster."
  type        = string
}

variable "aks_cluster_name" {
  description = "Name of the AKS cluster on which SQL Server will be deployed. Can be the same cluster as Materialize or a separate one."
  type        = string
}

variable "create_amd64_node_pool" {
  description = "Whether to create a dedicated amd64 AKS node pool for SQL Server using Terraform. Enable this when the cluster is arm64-only and SQL Server image requires amd64."
  type        = bool
  default     = true
  nullable    = false
}

variable "amd64_node_pool_name" {
  description = "Name of the Terraform-managed amd64 node pool. Must be 1-12 lowercase alphanumeric characters."
  type        = string
  default     = "sqlx64"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]{1,12}$", var.amd64_node_pool_name))
    error_message = "amd64_node_pool_name must be 1-12 characters and contain only lowercase letters and numbers."
  }
}

variable "amd64_node_pool_vm_size" {
  description = "VM size for the dedicated amd64 node pool (for example Standard_D2s_v3)."
  type        = string
  default     = "Standard_D2s_v3"
  nullable    = false
}

variable "amd64_node_pool_vnet_subnet_id" {
  description = "Subnet resource ID for the dedicated amd64 node pool. For existing Azure CNI clusters, set this to the AKS subnet ID to avoid in-place node pool mutations."
  type        = string
  default     = null
}

variable "amd64_node_pool_enable_auto_scaling" {
  description = "Enable autoscaling for the dedicated amd64 node pool."
  type        = bool
  default     = false
  nullable    = false
}

variable "amd64_node_pool_node_count" {
  description = "Fixed node count for the dedicated amd64 node pool when autoscaling is disabled."
  type        = number
  default     = 1

  validation {
    condition     = var.amd64_node_pool_node_count >= 1
    error_message = "amd64_node_pool_node_count must be at least 1."
  }
}

variable "amd64_node_pool_min_count" {
  description = "Minimum node count for the dedicated amd64 node pool when autoscaling is enabled."
  type        = number
  default     = 1

  validation {
    condition     = var.amd64_node_pool_min_count >= 1
    error_message = "amd64_node_pool_min_count must be at least 1."
  }
}

variable "amd64_node_pool_max_count" {
  description = "Maximum node count for the dedicated amd64 node pool when autoscaling is enabled. Keep this within your regional vCPU quota."
  type        = number
  default     = 1

  validation {
    condition     = var.amd64_node_pool_max_count >= 1
    error_message = "amd64_node_pool_max_count must be at least 1."
  }
}

variable "node_pool_tags" {
  description = "Tags applied to the Terraform-managed amd64 node pool."
  type        = map(string)
  default     = {}
}

variable "force_amd64_scheduling" {
  description = "Adds kubernetes.io/arch=amd64 to SQL Server pod nodeSelector. Keep this enabled for SQL Server 2022 container images."
  type        = bool
  default     = true
  nullable    = false
}

# ---------------------------------------------------------------------------
# Identity & image
# ---------------------------------------------------------------------------

variable "namespace" {
  description = "Kubernetes namespace for SQL Server resources."
  type        = string
  default     = "sql-server"
  nullable    = false
}

variable "name_prefix" {
  description = "Prefix applied to every Kubernetes resource name."
  type        = string
  default     = "mssql"
  nullable    = false
}

variable "image_tag" {
  description = "SQL Server 2022 image tag. '2022-latest' = latest stable cumulative update."
  type        = string
  default     = "2022-latest"
  nullable    = false
}

variable "sa_password" {
  description = "SA password. If null, a strong 24-character password is generated (retrieve with `terraform output -raw sa_password`)."
  type        = string
  default     = null
  sensitive   = true
}

variable "sql_server_pid" {
  description = "SQL Server edition. Developer is full-featured and free for non-production / load testing use."
  type        = string
  default     = "Developer"
  nullable    = false
}

variable "enable_sql_agent" {
  description = "Enable SQL Server Agent (required for CDC, which Materialize uses as a source)."
  type        = bool
  default     = true
  nullable    = false
}

# ---------------------------------------------------------------------------
# Performance – CPU
# ---------------------------------------------------------------------------

variable "cpu_request" {
  description = "Guaranteed CPU cores. Start at 2; increase for heavier load tests."
  type        = string
  default     = "2"
  nullable    = false
}

variable "cpu_limit" {
  description = "Maximum CPU cores. Set higher than cpu_request to allow burst. Suggested values for load tiers: light=4, medium=8, heavy=16."
  type        = string
  default     = "4"
  nullable    = false
}

# ---------------------------------------------------------------------------
# Performance – Memory
# ---------------------------------------------------------------------------

variable "memory_request" {
  description = "Guaranteed memory. Minimum usable is 2Gi. Suggested: light=4Gi, medium=16Gi, heavy=32Gi."
  type        = string
  default     = "4Gi"
  nullable    = false
}

variable "memory_limit" {
  description = "Hard memory ceiling. SQL Server is OOM-killed if exceeded. Should match or exceed memory_request."
  type        = string
  default     = "8Gi"
  nullable    = false
}

variable "max_server_memory_mb" {
  description = "Explicit SQL Server max server memory (MB). Null = auto from container limits. Set to (memory_limit_in_mb - 512) when tuning for load tests, e.g. 7680 for an 8Gi limit."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

variable "data_storage_size" {
  description = "PVC size for SQL Server data and logs. Start at 32Gi; increase before large-scale tests. Supports online resize without pod restart."
  type        = string
  default     = "32Gi"
  nullable    = false
}

variable "storage_class_name" {
  description = "AKS StorageClass. managed-csi-premium (common default) = Premium SSD. Some clusters use managed-premium. Switch to managed-ultra-csi where available for maximum IOPS during load tests."
  type        = string
  default     = "managed-csi-premium"
  nullable    = false
}

# ---------------------------------------------------------------------------
# Scheduling
# ---------------------------------------------------------------------------

variable "node_selector" {
  description = "Labels to pin the SQL Server pod to a specific node pool. Empty = schedule on any node."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for tainted node pools (e.g. dedicated SQL / load-test pools)."
  type = list(object({
    key      = string
    operator = string
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "service_type" {
  description = "Kubernetes Service type. ClusterIP = in-cluster only (recommended). LoadBalancer = externally reachable."
  type        = string
  default     = "ClusterIP"
  nullable    = false
}

variable "service_annotations" {
  description = "Service annotations. Example for internal Azure LB: { 'service.beta.kubernetes.io/azure-load-balancer-internal' = 'true' }."
  type        = map(string)
  default     = {}
}

variable "create_materialize_sql_egress_policy" {
  description = "Create a NetworkPolicy in the Materialize namespace that allows egress to SQL Server on TCP 1433."
  type        = bool
  default     = true
  nullable    = false
}

variable "materialize_namespace" {
  description = "Namespace where Materialize runs. Used when creating egress policy to SQL Server."
  type        = string
  default     = "materialize-environment"
  nullable    = false
}

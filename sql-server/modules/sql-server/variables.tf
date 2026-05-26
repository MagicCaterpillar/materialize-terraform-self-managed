# ---------------------------------------------------------------------------
# Identity & Configuration
# ---------------------------------------------------------------------------

variable "namespace" {
  description = "Kubernetes namespace in which all SQL Server resources are created."
  type        = string
  default     = "sql-server"
  nullable    = false
}

variable "name_prefix" {
  description = "Prefix applied to every Kubernetes resource name (deployment, service, PVC, secret)."
  type        = string
  default     = "mssql"
  nullable    = false
}

variable "image_tag" {
  description = "SQL Server 2022 container image tag. '2022-latest' tracks the latest stable cumulative update. Pin to a specific CU (e.g. '2022-CU16-ubuntu-22.04') for reproducible deployments."
  type        = string
  default     = "2022-latest"
  nullable    = false
}

variable "sa_password" {
  description = "SA (system administrator) password. Must satisfy SQL Server complexity rules: >= 8 chars, mix of upper, lower, digit and symbol. If null, a 24-character random password is generated."
  type        = string
  default     = null
  sensitive   = true
}

variable "sql_server_pid" {
  description = "SQL Server product edition. 'Developer' is full-featured and free for non-production use (recommended for load testing). Options: Developer, Express, Standard, Enterprise, EnterpriseCore."
  type        = string
  default     = "Developer"
  nullable    = false

  validation {
    condition     = contains(["Developer", "Express", "Standard", "Enterprise", "EnterpriseCore"], var.sql_server_pid)
    error_message = "sql_server_pid must be one of: Developer, Express, Standard, Enterprise, EnterpriseCore."
  }
}

variable "enable_sql_agent" {
  description = "Enable SQL Server Agent. Required for Change Data Capture (CDC), which Materialize uses as a source. Should remain true in most cases."
  type        = bool
  default     = true
  nullable    = false
}

# ---------------------------------------------------------------------------
# Performance – CPU
# Guidance: start with defaults; double cpu_limit when beginning load tests;
#           increase cpu_request to match limit to guarantee scheduling on a
#           node with sufficient headroom.
# ---------------------------------------------------------------------------

variable "cpu_request" {
  description = "Guaranteed CPU cores reserved for the SQL Server pod. Kubernetes schedules the pod only on nodes that can satisfy this request."
  type        = string
  default     = "2"
  nullable    = false
}

variable "cpu_limit" {
  description = "Maximum CPU cores the SQL Server pod may use. Set higher than cpu_request to allow burst capacity during load tests. For very high workloads consider 8–16."
  type        = string
  default     = "4"
  nullable    = false
}

# ---------------------------------------------------------------------------
# Performance – Memory
# Guidance: SQL Server minimum is 2 Gi. For CDC + moderate query load, 4–8 Gi
#           is a reasonable start. For heavy load testing, 16–32 Gi is typical.
#           Always keep max_server_memory_mb <= (memory_limit in MB) - 512 MB
#           to leave headroom for OS processes inside the container.
# ---------------------------------------------------------------------------

variable "memory_request" {
  description = "Guaranteed memory for the SQL Server pod (e.g. '4Gi', '16Gi'). Minimum usable is 2Gi."
  type        = string
  default     = "4Gi"
  nullable    = false
}

variable "memory_limit" {
  description = "Hard memory ceiling for the SQL Server pod (e.g. '8Gi', '32Gi'). SQL Server is OOM-killed if it exceeds this value, so set max_server_memory_mb accordingly."
  type        = string
  default     = "8Gi"
  nullable    = false
}

variable "max_server_memory_mb" {
  description = "SQL Server 'max server memory' in MB (sets MSSQL_MEMORY_LIMIT_MB). Null = SQL Server auto-detects from container cgroup limits (default in SQL Server 2022). Set explicitly when tuning for load tests, e.g. 6144 with an 8Gi memory_limit."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Storage
# Guidance: Azure Disk storage classes available in AKS:
#   managed-csi           – Standard SSD  (~3 IOPS/GiB,   max 6000 IOPS)
#   managed-premium-csi   – Premium SSD   (~5 IOPS/GiB,  max 20000 IOPS) ← default
#   managed-ultra-csi     – Ultra Disk    (configurable,  max 160000 IOPS) for peak load tests
#
# For data_storage_size: start at 32Gi; increase before running large-scale
# tests. Note: Azure Disk PVCs can be resized online without pod restart if the
# storage class supports volume expansion (all three above do).
# ---------------------------------------------------------------------------

variable "data_storage_size" {
  description = "Size of the persistent volume for SQL Server data, logs and backups (e.g. '32Gi', '256Gi', '1Ti'). Stored externally from the container — data survives pod restarts and recreation."
  type        = string
  default     = "32Gi"
  nullable    = false
}

variable "storage_class_name" {
  description = "Kubernetes StorageClass for the SQL Server PVC. See storage guidance above. managed-csi-premium is a common AKS premium default (some clusters use managed-premium); switch to managed-ultra-csi where available for maximum IOPS during load tests."
  type        = string
  default     = "managed-csi-premium"
  nullable    = false
}

# ---------------------------------------------------------------------------
# Scheduling
# ---------------------------------------------------------------------------

variable "node_selector" {
  description = "Label map to pin the SQL Server pod to a specific node pool (e.g. { 'agentpool' = 'sqlpool' }). Empty map = no restriction."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations allowing the SQL Server pod to schedule onto tainted nodes (e.g. dedicated SQL Server or load-test node pools)."
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
  description = "Kubernetes Service type. 'ClusterIP' (recommended) restricts access to in-cluster clients including Materialize. 'LoadBalancer' exposes SQL Server externally — combine with service_annotations to make it an internal Azure LB."
  type        = string
  default     = "ClusterIP"
  nullable    = false

  validation {
    condition     = contains(["ClusterIP", "LoadBalancer", "NodePort"], var.service_type)
    error_message = "service_type must be one of: ClusterIP, LoadBalancer, NodePort."
  }
}

variable "service_annotations" {
  description = "Annotations applied to the Service. To create an Azure Internal Load Balancer, set: { 'service.beta.kubernetes.io/azure-load-balancer-internal' = 'true' }."
  type        = map(string)
  default     = {}
}

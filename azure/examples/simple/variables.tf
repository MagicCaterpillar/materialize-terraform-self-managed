variable "subscription_id" {
  description = "The ID of the Azure subscription"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group which will be created."
  type        = string
}

variable "location" {
  description = "The location of the Azure subscription"
  type        = string
  default     = "westus2"
}

variable "name_prefix" {
  description = "The prefix of the Azure subscription"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources created."
  type        = map(string)
}

variable "ingress_cidr_blocks" {
  description = "CIDR blocks that can reach the Azure LoadBalancer frontends."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition = alltrue([
      for cidr in var.ingress_cidr_blocks : can(cidrhost(cidr, 0))
    ])
    error_message = "All ingress_cidr_blocks must be valid CIDR notation (e.g., '10.0.0.0/8' or '0.0.0.0/0')."
  }
}

variable "license_key" {
  description = "Materialize license key"
  type        = string
  default     = null
  sensitive   = true
}

variable "k8s_apiserver_authorized_networks" {
  description = "List of authorized IP ranges that can access the Kubernetes API server when public access is available. Defaults to ['0.0.0.0/0'] (allow all). For production, restrict to specific IPs (e.g., ['203.0.113.0/24'])"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Explicit default: allow all IPs
  nullable    = true

  validation {
    condition = (
      var.k8s_apiserver_authorized_networks == null ||
      alltrue([
        for cidr in var.k8s_apiserver_authorized_networks :
        can(cidrhost(cidr, 0))
      ])
    )
    error_message = "All k8s_apiserver_authorized_networks must be valid CIDR blocks (e.g., '203.0.113.0/24')."
  }
}


variable "internal_load_balancer" {
  description = "Whether to use an internal load balancer"
  type        = bool
  default     = true
}

variable "crd_version" {
  description = "CRD API version to use for the Materialize instance (v1alpha1 or v1alpha2). We recommend v1alpha2, but default to v1alpha1 for backwards compatibility. We will change this default in an upcoming major release."
  type        = string
  default     = "v1alpha1"
  nullable    = false

  validation {
    condition     = contains(["v1alpha1", "v1alpha2"], var.crd_version)
    error_message = "CRD version must be either 'v1alpha1' or 'v1alpha2'"
  }
}

variable "enable_observability" {
  description = "Enable Prometheus and Grafana monitoring stack for Materialize"
  type        = bool
  default     = false
}

variable "default_node_pool_vm_size" {
  description = "VM size for the AKS default node pool"
  type        = string
  default     = "Standard_D4pds_v6"
  nullable    = false
}

variable "default_node_pool_enable_auto_scaling" {
  description = "Whether autoscaling is enabled for the AKS default node pool"
  type        = bool
  default     = true
  nullable    = false
}

variable "default_node_pool_min_count" {
  description = "Minimum node count for the AKS default node pool when autoscaling is enabled"
  type        = number
  default     = 2

  validation {
    condition     = !var.default_node_pool_enable_auto_scaling || var.default_node_pool_min_count > 0
    error_message = "default_node_pool_min_count must be greater than 0 when autoscaling is enabled."
  }
}

variable "default_node_pool_max_count" {
  description = "Maximum node count for the AKS default node pool when autoscaling is enabled"
  type        = number
  default     = 5

  validation {
    condition     = !var.default_node_pool_enable_auto_scaling || var.default_node_pool_max_count >= var.default_node_pool_min_count
    error_message = "default_node_pool_max_count must be greater than or equal to default_node_pool_min_count when autoscaling is enabled."
  }
}

variable "default_node_pool_node_count" {
  description = "Fixed node count for the AKS default node pool when autoscaling is disabled"
  type        = number
  default     = 1

  validation {
    condition     = var.default_node_pool_enable_auto_scaling || var.default_node_pool_node_count > 0
    error_message = "default_node_pool_node_count must be greater than 0 when autoscaling is disabled."
  }
}

variable "materialize_node_pool_vm_size" {
  description = "VM size for the Materialize-dedicated node pool"
  type        = string
  default     = "Standard_E4pds_v6"
  nullable    = false
}

variable "materialize_node_pool_auto_scaling_enabled" {
  description = "Whether autoscaling is enabled for the Materialize-dedicated node pool"
  type        = bool
  default     = true
  nullable    = false
}

variable "materialize_node_pool_min_nodes" {
  description = "Minimum node count for the Materialize node pool when autoscaling is enabled"
  type        = number
  default     = 2

  validation {
    condition     = !var.materialize_node_pool_auto_scaling_enabled || var.materialize_node_pool_min_nodes > 0
    error_message = "materialize_node_pool_min_nodes must be greater than 0 when autoscaling is enabled."
  }
}

variable "materialize_node_pool_max_nodes" {
  description = "Maximum node count for the Materialize node pool when autoscaling is enabled"
  type        = number
  default     = 5

  validation {
    condition     = !var.materialize_node_pool_auto_scaling_enabled || var.materialize_node_pool_max_nodes >= var.materialize_node_pool_min_nodes
    error_message = "materialize_node_pool_max_nodes must be greater than or equal to materialize_node_pool_min_nodes when autoscaling is enabled."
  }
}

variable "materialize_node_pool_node_count" {
  description = "Fixed node count for the Materialize node pool when autoscaling is disabled"
  type        = number
  default     = 1

  validation {
    condition     = var.materialize_node_pool_auto_scaling_enabled || var.materialize_node_pool_node_count > 0
    error_message = "materialize_node_pool_node_count must be greater than 0 when autoscaling is disabled."
  }
}

variable "project_id" {
  description = "The ID of the project where resources will be created"
  type        = string
}

variable "region" {
  description = "The region where resources will be created"
  type        = string
  default     = "us-central1"
}

variable "labels" {
  description = "Labels to apply to resources created."
  type        = map(string)
}

variable "name_prefix" {
  description = "Prefix to be used for resource names"
  type        = string
  default     = "materialize"
}

variable "license_key" {
  description = "Materialize license key"
  type        = string
  default     = null
  sensitive   = true
}

variable "ingress_cidr_blocks" {
  description = "The CIDR blocks that are allowed to reach the Load Balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  nullable    = true

  validation {
    condition = var.ingress_cidr_blocks == null || alltrue([
      for cidr in var.ingress_cidr_blocks : can(cidrhost(cidr, 0))
    ])
    error_message = "All ingress_cidr_blocks must be valid CIDR notation (e.g., '10.0.0.0/8' or '0.0.0.0/0')."
  }
}

variable "k8s_apiserver_authorized_networks" {
  description = "The CIDR blocks that are allowed to reach the Kubernetes master endpoint."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [{
    cidr_block   = "0.0.0.0/0"
    display_name = "Default Placeholder for authorized networks"
  }]
  nullable = false

  validation {
    condition = alltrue([
      for network in var.k8s_apiserver_authorized_networks : can(cidrhost(network.cidr_block, 0))
    ])
    error_message = "All k8s_apiserver_authorized_networks must be valid CIDR notation (e.g., '10.0.0.0/8' or '0.0.0.0/0')."
  }
}

variable "internal_load_balancer" {
  description = "Whether to use an internal load balancer"
  type        = bool
  default     = true
}

variable "enable_observability" {
  description = "Enable Prometheus and Grafana monitoring stack for Materialize"
  type        = bool
  default     = false
}

# Ory variables
variable "ory_issuer_url" {
  description = "The public URL of the OAuth2 issuer (Hydra). Used for OIDC discovery. Example: https://auth.example.com/"
  type        = string
}

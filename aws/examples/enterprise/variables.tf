variable "aws_region" {
  description = "The AWS region where the resources will be created."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "The AWS profile to use for authentication."
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources created."
  type        = map(string)
}

variable "name_prefix" {
  description = "A prefix to add to all resource names."
  type        = string
}

variable "license_key" {
  description = "Materialize license key"
  type        = string
  sensitive   = true
}

variable "force_rollout" {
  description = "UUID to force a rollout"
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"
}

variable "request_rollout" {
  description = "UUID to request a rollout"
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"
}

variable "ingress_cidr_blocks" {
  description = "List of CIDR blocks to allow access to materialize Load Balancers. Only applied when Load Balancer is public."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  nullable    = true

  validation {
    condition     = var.ingress_cidr_blocks == null || alltrue([for cidr in var.ingress_cidr_blocks : can(cidrhost(cidr, 0))])
    error_message = "All CIDR blocks must be valid IPv4 CIDR notation (e.g., '10.0.0.0/16' or '0.0.0.0/0')."
  }
}

variable "k8s_apiserver_authorized_networks" {
  description = "List of CIDR blocks to allow public access to the EKS cluster endpoint"
  type        = list(string)
  nullable    = false
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for cidr in var.k8s_apiserver_authorized_networks : can(cidrhost(cidr, 0))])
    error_message = "All k8s_apiserver_authorized_networks valid IPv4 CIDR notation (e.g., '10.0.0.0/16' or '0.0.0.0/0')."
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
variable "ory_oel_registry" {
  description = "Base registry URL for Ory Enterprise License images. Example: europe-docker.pkg.dev/ory-artifacts"
  type        = string
}

variable "ory_oel_image_tag" {
  description = "Image tag for OEL images."
  type        = string
  default     = "26.2.3"
}

# TODO: Update auth mechanism once Materialize private registry is set up.
# Currently uses a GCP service account key file for Ory's Artifact Registry.
variable "ory_oel_key_file" {
  description = "Path to the GCP service account JSON key file for pulling OEL images from Ory's Artifact Registry."
  type        = string
}

variable "ory_hydra_hostname" {
  description = "External hostname for the Hydra OAuth2 public API. Used as the OIDC issuer URL. Example: hydra.internal.example.com"
  type        = string
}

variable "ory_ui_hostname" {
  description = "External hostname for the Ory selfservice UI (login/consent pages). Example: auth.internal.example.com"
  type        = string
}

variable "ory_kratos_hostname" {
  description = "External hostname for the Kratos public API. Kratos flows return browser-facing URLs using this hostname. Example: kratos.internal.example.com"
  type        = string
}

variable "materialize_console_hostname" {
  description = "External hostname for the Materialize console. Used to construct the OAuth2 redirect URI. Example: materialize.internal.example.com"
  type        = string
}

variable "cert_issuer_ref" {
  description = "Bring-your-own cert-manager (Cluster)Issuer used to sign the browser-facing TLS certs (Materialize console / balancerd, Hydra, Kratos, selfservice UI). When null, the example falls back to the built-in self-signed issuer for browser-facing certs (the demo path). The internal mTLS cert (with *.cluster.local SANs) always uses the self-signed cluster issuer because public ACME issuers like Let's Encrypt cannot sign cluster.local. See the README for an example of plugging in a Let's Encrypt + Cloudflare DNS-01 issuer."
  type = object({
    name = string
    kind = string
  })
  default = null
}

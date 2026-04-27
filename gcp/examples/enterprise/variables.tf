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
  description = "Bring-your-own cert-manager ClusterIssuer used for all TLS certificates in this example (Materialize console/balancerd/internal, Hydra, Kratos, selfservice UI). When null, the example creates either the built-in self-signed issuer (default) or a Let's Encrypt issuer (when var.enable_letsencrypt = true)."
  type = object({
    name = string
    kind = string
  })
  default = null
}

variable "enable_letsencrypt" {
  description = "When true, the example provisions a Let's Encrypt ClusterIssuer (via var.letsencrypt_dns_provider for the ACME dns-01 challenge) and uses it for all TLS certs. Requires real DNS pointed at the LB IPs in var.letsencrypt_dns_zones. Ignored when var.cert_issuer_ref is set."
  type        = bool
  default     = false
  nullable    = false
}

variable "letsencrypt_email" {
  description = "Contact email for Let's Encrypt account registration. Required when var.enable_letsencrypt = true."
  type        = string
  default     = null
}

variable "letsencrypt_acme_environment" {
  description = "Let's Encrypt environment. 'staging' avoids the production rate limits while iterating but issues untrusted certs; 'production' issues browser-trusted certs. Default is staging so first applies don't burn the production rate-limit budget."
  type        = string
  default     = "staging"
  nullable    = false

  validation {
    condition     = contains(["staging", "production"], var.letsencrypt_acme_environment)
    error_message = "letsencrypt_acme_environment must be 'staging' or 'production'."
  }
}

variable "letsencrypt_dns_provider" {
  description = "DNS provider used to satisfy ACME dns-01 challenges. Currently only 'cloudflare' is supported."
  type        = string
  default     = "cloudflare"
  nullable    = false

  validation {
    condition     = contains(["cloudflare"], var.letsencrypt_dns_provider)
    error_message = "letsencrypt_dns_provider must be 'cloudflare'."
  }
}

variable "letsencrypt_dns_zones" {
  description = "DNS zones (apex domains) the Let's Encrypt issuer is allowed to solve challenges for. Required when var.enable_letsencrypt = true. Example: [\"example.com\"] when your hostnames are like console.example.com or hydra.mz.example.com."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:Read and DNS:Edit permission scoped to var.letsencrypt_dns_zones. Required when var.enable_letsencrypt = true and var.letsencrypt_dns_provider = 'cloudflare'. Create at https://dash.cloudflare.com/profile/api-tokens."
  type        = string
  default     = null
  sensitive   = true
}

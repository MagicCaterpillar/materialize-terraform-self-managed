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

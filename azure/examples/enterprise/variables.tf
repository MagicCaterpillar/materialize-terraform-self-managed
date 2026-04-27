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

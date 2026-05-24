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
  description = "Materialize license key JWT. Required for this example: used both by Materialize itself and as the password in the imagePullSecret that authenticates to the Materialize-hosted Ory registry proxy."
  type        = string
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
  description = "List of CIDR blocks (with display names) allowed to reach the GKE master endpoint. Required (no default) so that an enterprise deployment makes an explicit choice instead of inheriting an open default. Pass a single 0.0.0.0/0 entry to allow all (lab use); production should pin a tight allowlist."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
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
  default     = true
}

# Ory variables
variable "ory_oel_registry" {
  description = "Base registry URL for Ory Enterprise License images. Defaults to the production Materialize-hosted registry proxy. Override for staging (ory.registry.staging.cloud.materialize.com/ory-artifacts) or a dev stack."
  type        = string
  default     = "ory.registry.cloud.materialize.com/ory-artifacts"
}

variable "ory_oel_image_tag" {
  description = "Image tag for OEL images."
  type        = string
  default     = "26.2.3"
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

variable "upstream_oidc_providers" {
  description = "Upstream OIDC providers to expose as social sign-in methods on the Kratos selfservice UI. Each entry renders as a 'Sign in with X' button on the login page. Leave as [] for password-only login. Register the redirect URI https://<ory_kratos_hostname>/self-service/methods/oidc/callback/<id> at the upstream IdP."
  type = list(object({
    id            = string
    provider      = optional(string, "generic")
    client_id     = string
    client_secret = string
    issuer_url    = string
    scope         = optional(list(string), ["openid", "email", "profile"])
    label         = optional(string)
  }))
  default   = []
  nullable  = false
  sensitive = true
}

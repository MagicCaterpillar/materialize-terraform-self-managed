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

variable "instance_name" {
  description = "Name of the Materialize instance"
  type        = string
  nullable    = false
}

variable "create_namespace" {
  description = "Whether to create the Kubernetes namespace. Set to false if the namespace already exists."
  type        = bool
  default     = true
  nullable    = false
}

variable "instance_namespace" {
  description = "Kubernetes namespace for the instance."
  type        = string
  nullable    = false
}

variable "metadata_backend_url" {
  description = "PostgreSQL connection URL for metadata backend"
  type        = string
  sensitive   = true
  nullable    = false
}

variable "persist_backend_url" {
  description = "S3 connection URL for persist backend"
  type        = string
  nullable    = false
}

variable "license_key" {
  description = "Materialize license key"
  type        = string
  default     = null
  sensitive   = true
}

# Environmentd Configuration
variable "environmentd_version" {
  description = "Version of environmentd to use"
  type        = string
  default     = "v26.25.0" # META: mz version
  nullable    = false
}

variable "environmentd_extra_env" {
  description = "Extra environment variables for environmentd"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "environmentd_extra_args" {
  description = "Extra command line arguments for environmentd"
  type        = list(string)
  default     = []
}

# Resource Requirements
variable "cpu_request" {
  description = "CPU request for environmentd"
  type        = string
  default     = "1"
  nullable    = false
}

variable "memory_request" {
  description = "Memory request for environmentd"
  type        = string
  default     = "4095Mi"
  nullable    = false
}

variable "memory_limit" {
  description = "Memory limit for environmentd"
  type        = string
  default     = "4Gi"
  nullable    = false
}

# Rollout Configuration
variable "rollout_strategy" {
  description = "Strategy to use for rollouts"
  type        = string
  default     = "WaitUntilReady"
  nullable    = false
  validation {
    condition     = contains(["WaitUntilReady", "ImmediatelyPromoteCausingDowntime", "ManuallyPromote"], var.rollout_strategy)
    error_message = "Rollout strategy must be 'WaitUntilReady', 'ImmediatelyPromoteCausingDowntime', or 'ManuallyPromote'"
  }
}

variable "request_rollout" {
  description = "UUID to request a rollout (v1alpha1 only, ignored for v1alpha2)"
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"

  validation {
    condition     = (var.request_rollout == null && var.crd_version != "v1alpha1") || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.request_rollout))
    error_message = "Request rollout must be a valid UUID in the format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  }
}

variable "force_rollout" {
  description = "UUID to force a rollout"
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.force_rollout))
    error_message = "Force rollout must be a valid UUID in the format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  }
}

# Balancer Resource Requirements
variable "balancer_memory_request" {
  # NOTE: 256Mi is fine for light use but OOM-kills balancerd under high
  # connection load (observed during a HammerDB + Locust load test against a
  # self-managed Azure/AKS deployment — balancerd, not the cluster, was the
  # ceiling). Override to ~2Gi for high-connection / load-test workloads.
  description = "Memory request for balancer. 256Mi OOM-kills under high connection load; raise to ~2Gi for high-connection workloads."
  type        = string
  default     = "256Mi"
  nullable    = false
}

variable "balancer_memory_limit" {
  # See balancer_memory_request: raise alongside it (e.g. 2Gi) for
  # high-connection / load-test workloads to avoid OOM kills.
  description = "Memory limit for balancer. 256Mi OOM-kills under high connection load; raise to ~2Gi for high-connection workloads."
  type        = string
  default     = "256Mi"
  nullable    = false
}

variable "balancer_cpu_request" {
  description = "CPU request for balancer"
  type        = string
  default     = "100m"
  nullable    = false
}

variable "authenticator_kind" {
  description = "Kind of authenticator to use for Materialize instance"
  type        = string
  default     = "None"
  nullable    = false
  validation {
    condition     = contains(["None", "Password", "Sasl", "Oidc"], var.authenticator_kind)
    error_message = "Authenticator kind must be one of: 'None', 'Password', 'Sasl', or 'Oidc'"
  }
}

variable "external_login_password_mz_system" {
  description = "Password for external login to mz_system. Must be set if authenticator_kind is 'Password', 'Sasl', or 'Oidc'."
  type        = string
  default     = null
  sensitive   = true
}

variable "service_account_annotations" {
  description = "Annotations for the service account associated with the materialize instance. Useful for IAM roles assigned to the service account."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "pod_labels" {
  description = "Labels for the materialize instance pod"
  type        = map(string)
  default     = {}
  nullable    = false
}


variable "issuer_ref" {
  description = "Default cert-manager (Cluster)Issuer used for the instance's TLS certificates. Used for both the external (browser-facing) certs and the internal mTLS certs unless overridden by var.internal_issuer_ref."
  type = object({
    name = string
    kind = string
  })
  default = null
}

variable "internal_issuer_ref" {
  description = "Optional override for the issuer used to sign cluster-internal mTLS certs (those with *.cluster.local SANs). Required when var.issuer_ref points at a public ACME issuer such as Let's Encrypt, since public CAs cannot sign cluster.local. When this is set, the short cluster service names ('balancerd', 'console') are also stripped from the external cert SANs because public ACME issuers reject single-label domains. When null, var.issuer_ref is used for both internal and external certs."
  type = object({
    name = string
    kind = string
  })
  default = null
}

variable "console_extra_dns_names" {
  description = "Additional DNS names to include in the console TLS certificate. Useful when the console is exposed via an external hostname (e.g., materialize.internal.example.com)."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "balancerd_extra_dns_names" {
  description = "Additional DNS names to include in the balancerd TLS certificate. Useful when balancerd is exposed via an external hostname."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "system_parameters" {
  description = "System parameters to configure for the Materialize instance. These are passed via a ConfigMap. Common parameters include max_connections, allowed_cluster_replica_sizes, max_clusters, max_sources, max_sinks. Set to null to skip creating the ConfigMap."
  type        = map(string)
  default     = {}
}

variable "enable_network_policies" {
  description = "Enable default-deny-ingress network policy for the instance namespace. Helm chart creates specific allow policies."
  type        = bool
  default     = true
  nullable    = false
}

variable "monitoring_namespace" {
  description = "Namespace where monitoring resources (Prometheus) are installed. Used for network policy to allow metrics scraping."
  type        = string
  default     = "monitoring"
  nullable    = false
}

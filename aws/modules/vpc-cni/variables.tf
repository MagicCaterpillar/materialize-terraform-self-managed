variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  nullable    = false
}

variable "chart_version" {
  description = "Version of the AWS VPC CNI Helm chart"
  type        = string
  default     = "v1.21.1"
  nullable    = false
}

variable "enable_network_policy" {
  description = "Enable Kubernetes NetworkPolicy support. Requires VPC CNI v1.14+ and Kubernetes 1.25+."
  type        = bool
  default     = true
  nullable    = false
}

variable "enable_policy_event_logs" {
  description = "Enable logging of network policy events to node/pod logs"
  type        = bool
  default     = true
  nullable    = false
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  type        = string
  nullable    = false
}

variable "oidc_issuer_url" {
  description = "URL of the OIDC issuer for the EKS cluster"
  type        = string
  nullable    = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Advanced CNI settings
variable "enable_prefix_delegation" {
  description = "Enable prefix delegation for higher pod density per node"
  type        = bool
  default     = false
  nullable    = false
}

variable "warm_prefix_target" {
  description = "Number of free prefixes to maintain per node when prefix delegation is enabled"
  type        = number
  default     = 1
  nullable    = false
}

variable "minimum_ip_target" {
  description = "Minimum number of IP addresses to keep available per node"
  type        = number
  default     = null
}

variable "warm_ip_target" {
  description = "Number of free IP addresses to maintain per node"
  type        = number
  default     = null
}

variable "adopt_existing_resources" {
  description = "Annotate existing VPC CNI resources (aws-node daemonset, serviceaccount, etc.) for Helm adoption. Set to true when installing on a cluster that already has the default VPC CNI installed."
  type        = bool
  default     = true
  nullable    = false
}

variable "kubeconfig_data" {
  description = "Contents of the kubeconfig used for kubectl commands during resource adoption."
  type        = string
  nullable    = false
}

variable "iam_permissions_boundary" {
  description = "ARN of the IAM permissions boundary to attach to all IAM roles created by this module. Required for BYOC deployments."
  type        = string
  default     = null
}

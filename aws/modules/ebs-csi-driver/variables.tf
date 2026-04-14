variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  nullable    = false
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster OIDC provider"
  type        = string
  nullable    = false
}

variable "oidc_issuer_url" {
  description = "URL of the EKS cluster OIDC issuer"
  type        = string
  nullable    = false
}

variable "namespace" {
  description = "Namespace to install the EBS CSI driver"
  type        = string
  default     = "kube-system"
  nullable    = false
}

variable "service_account_name" {
  description = "Name of the Kubernetes service account"
  type        = string
  default     = "ebs-csi-controller-sa"
  nullable    = false
}

variable "chart_version" {
  description = "Version of the EBS CSI driver Helm chart"
  type        = string
  default     = "2.54.1"
  nullable    = false
}

variable "node_selector" {
  description = "Node selector for EBS CSI driver pods"
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "kms_key_id" {
  description = "The ARN of a KMS key to use for EBS volume encryption. If not specified, volumes will use AWS managed encryption."
  type        = string
  default     = null
}

variable "iam_permissions_boundary" {
  description = "ARN of the IAM permissions boundary to attach to all IAM roles created by this module. Required for BYOC deployments."
  type        = string
  default     = null
}

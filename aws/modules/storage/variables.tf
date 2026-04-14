variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  nullable    = false
}

variable "bucket_force_destroy" {
  description = "Enable force destroy for the S3 bucket"
  type        = bool
  default     = true
  nullable    = false
}

variable "enable_bucket_versioning" {
  description = "Enable versioning for the S3 bucket"
  type        = bool
  default     = true
  nullable    = false
}

variable "enable_bucket_encryption" {
  description = "Enable server-side encryption for the S3 bucket"
  type        = bool
  default     = true
  nullable    = false
}

variable "bucket_encryption_mode" {
  description = "Server-side encryption mode to apply (SSE-S3 by default)"
  type        = string
  default     = "SSE-S3"
  nullable    = false

  validation {
    condition     = contains(["SSE-S3", "SSE-KMS"], var.bucket_encryption_mode)
    error_message = "bucket_encryption_mode must be either \"SSE-S3\" or \"SSE-KMS\"."
  }
}

variable "bucket_kms_key_arn" {
  description = "ARN of the KMS key to use when bucket_encryption_mode is SSE-KMS"
  type        = string
  default     = null
}

variable "bucket_lifecycle_rules" {
  description = "List of lifecycle rules for the S3 bucket"
  type = list(object({
    id                                 = string
    enabled                            = bool
    prefix                             = string
    transition_days                    = number
    transition_storage_class           = string
    noncurrent_version_expiration_days = number
  }))
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  type        = string
  nullable    = false
}

variable "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for the EKS cluster"
  type        = string
  nullable    = false
}

variable "service_account_namespace" {
  description = "Kubernetes namespace for the Materialize instance service account that will use IRSA"
  type        = string
  nullable    = false
}

variable "service_account_name" {
  description = "Kubernetes service account name for the Materialize instance that will use IRSA"
  type        = string
  nullable    = false
}

variable "iam_permissions_boundary" {
  description = "ARN of the IAM permissions boundary to attach to all IAM roles created by this module. Required for BYOC deployments."
  type        = string
  default     = null
}

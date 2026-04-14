variable "namespace" {
  description = "Namespace to install the AWS LBC"
  type        = string
  default     = "kube-system"
  nullable    = false
}

variable "name_prefix" {
  description = "Prefix to use for AWS LBC resources"
  type        = string
  nullable    = false
}

variable "service_account_name" {
  description = "Name of the Kubernetes service account used by the AWS LBC"
  type        = string
  default     = "aws-load-balancer-controller"
  nullable    = false
}

variable "iam_name" {
  description = "Name of the AWS IAM role and policy"
  type        = string
  default     = "albc"
  nullable    = false
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
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

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region of the VPC"
  type        = string
  nullable    = false
}

variable "node_selector" {
  description = "Node selector for AWS Load Balancer Controller pods."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "iam_permissions_boundary" {
  description = "ARN of the IAM permissions boundary to attach to all IAM roles created by this module. Required for BYOC deployments."
  type        = string
  default     = null
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name = "${var.name_prefix}-eks"

  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.k8s_apiserver_authorized_networks
  cluster_endpoint_private_access      = true

  cluster_enabled_log_types = var.cluster_enabled_log_types

  node_security_group_additional_rules = {
    mz_ingress_http = {
      description = "Ingress to materialize balancers HTTP"
      protocol    = "tcp"
      from_port   = 6876
      to_port     = 6876
      type        = "ingress"
      cidr_blocks = var.materialize_node_ingress_cidrs
    }
    mz_ingress_pgwire = {
      description = "Ingress to materialize balancers pgwire"
      protocol    = "tcp"
      from_port   = 6875
      to_port     = 6875
      type        = "ingress"
      cidr_blocks = var.materialize_node_ingress_cidrs
    }
    mz_ingress_nlb_health_checks = {
      description = "Ingress to materialize balancer health checks and console"
      protocol    = "tcp"
      from_port   = 8080
      to_port     = 8080
      type        = "ingress"
      cidr_blocks = var.materialize_node_ingress_cidrs
    }
    orchestratord_ingress_conversion_webhooks = {
      description                   = "Ingress to materialize orchestratord for conversion webhooks"
      protocol                      = "tcp"
      from_port                     = 8001
      to_port                       = 8001
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  # Cluster access entry
  # To add the current caller identity as an administrator
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  # pulumi-terraform-module serialises unset list inputs as null, which
  # the upstream `kms` submodule's `aws_iam_policy_document.this` rejects
  # ("Null values are not allowed").  Pass explicit empty lists so KMS
  # envelope encryption for k8s secrets stays enabled.
  kms_key_administrators            = []
  kms_key_users                     = []
  kms_key_service_users             = []
  kms_key_source_policy_documents   = []
  kms_key_override_policy_documents = []

  # useful to disable this when prefix might be too long and hit following char limit
  # expected length of name_prefix to be in the range (1 - 38)
  iam_role_use_name_prefix = var.iam_role_use_name_prefix

  iam_role_permissions_boundary = var.iam_permissions_boundary

  tags = var.tags
}

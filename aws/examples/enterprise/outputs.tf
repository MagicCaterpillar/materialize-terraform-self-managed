# Networking outputs
output "networking" {
  description = "Networking details"
  value = {
    vpc_id             = module.networking.vpc_id
    private_subnet_ids = module.networking.private_subnet_ids
    public_subnet_ids  = module.networking.public_subnet_ids
  }
}

# Cluster outputs
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "The ARN of the OIDC Provider"
  value       = module.eks.oidc_provider_arn
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster for the OpenID Connect identity provider"
  value       = module.eks.cluster_oidc_issuer_url
}

# Database outputs
output "database_endpoint" {
  description = "RDS instance endpoint"
  value       = module.database.db_instance_endpoint
}

output "database_name" {
  description = "RDS instance name"
  value       = module.database.db_instance_name
}

output "database_username" {
  description = "RDS instance username"
  value       = module.database.db_instance_username
  sensitive   = true
}

# Storage outputs
output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = module.storage.bucket_name
}

output "materialize_s3_role_arn" {
  description = "The ARN of the IAM role for Materialize"
  value       = module.storage.materialize_s3_role_arn
}

# Materialize component outputs
output "operator" {
  description = "Materialize operator details"
  value = {
    namespace      = module.operator.operator_namespace
    release_name   = module.operator.operator_release_name
    release_status = module.operator.operator_release_status
  }
}

output "materialize_instance_name" {
  description = "Materialize instance name"
  value       = module.materialize_instance.instance_name
}

output "materialize_instance_namespace" {
  description = "Materialize instance namespace"
  value       = module.materialize_instance.instance_namespace
}

output "materialize_instance_resource_id" {
  description = "Materialize instance resource ID"
  value       = module.materialize_instance.instance_resource_id
}

output "materialize_instance_metadata_backend_url" {
  description = "Materialize instance metadata backend URL"
  value       = module.materialize_instance.metadata_backend_url
  sensitive   = true
}

output "materialize_instance_persist_backend_url" {
  description = "Materialize instance persist backend URL"
  value       = module.materialize_instance.persist_backend_url
  sensitive   = true
}

# Load balancer outputs
output "nlb_arn" {
  description = "ARN of the Materialize NLB."
  value       = module.materialize_nlb.nlb_arn
}

output "nlb_dns_name" {
  description = "DNS name of the Materialize NLB."
  value       = module.materialize_nlb.nlb_dns_name
}

output "external_login_password_mz_system" {
  description = "Password for the external login to the Materialize instance"
  value       = random_password.external_login_password_mz_system.result
  sensitive   = true
}

output "rds_kms_key_alias" {
  description = "KMS Key used to encrypt the RDS instance"
  value       = module.database.kms_key_alias
}

output "rds_kms_key_arn" {
  description = "KMS Key used to encrypt the RDS instance"
  value       = module.database.kms_key_arn
}

# Observability outputs (only when enabled)
output "prometheus_url" {
  description = "Internal URL for Prometheus server"
  value       = var.enable_observability ? module.prometheus[0].prometheus_url : null
}

output "grafana_url" {
  description = "Internal URL for Grafana"
  value       = var.enable_observability ? module.grafana[0].grafana_url : null
}

output "grafana_admin_password" {
  description = "`admin` password for Grafana"
  value       = var.enable_observability ? module.grafana[0].admin_password : null
  sensitive   = true
}

# Ory outputs
output "ory_kratos_database_endpoint" {
  description = "RDS instance endpoint for Ory Kratos"
  value       = module.ory_kratos_database.db_instance_endpoint
}

output "ory_hydra_database_endpoint" {
  description = "RDS instance endpoint for Ory Hydra"
  value       = module.ory_hydra_database.db_instance_endpoint
}

output "ory_kratos" {
  description = "Ory Kratos deployment details"
  value = {
    public_url     = module.ory_kratos.public_url
    admin_url      = module.ory_kratos.admin_url
    namespace      = module.ory_kratos.namespace
    release_name   = module.ory_kratos.release_name
    release_status = module.ory_kratos.release_status
  }
}

output "ory_hydra" {
  description = "Ory Hydra deployment details"
  value = {
    public_url     = module.ory_hydra.public_url
    admin_url      = module.ory_hydra.admin_url
    namespace      = module.ory_hydra.namespace
    release_name   = module.ory_hydra.release_name
    release_status = module.ory_hydra.release_status
  }
}

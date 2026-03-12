# Networking outputs
output "networking" {
  description = "Networking details"
  value = {
    vnet_id               = module.networking.vnet_id
    vnet_name             = module.networking.vnet_name
    aks_subnet_id         = module.networking.aks_subnet_id
    api_server_subnet_id  = module.networking.api_server_subnet_id
    postgres_subnet_id    = module.networking.postgres_subnet_id
    private_dns_zone_id   = module.networking.private_dns_zone_id
    nat_gateway_id        = module.networking.nat_gateway_id
    nat_gateway_public_ip = module.networking.nat_gateway_public_ip
    vnet_address_space    = module.networking.vnet_address_space
  }
}


# Cluster outputs
output "aks_cluster_name" {
  description = "The name of the AKS cluster"
  value       = module.aks.cluster_name
}

output "aks_cluster_id" {
  description = "The ID of the AKS cluster"
  value       = module.aks.cluster_id
}

output "aks_cluster_fqdn" {
  description = "The FQDN of the AKS cluster"
  value       = module.aks.cluster_fqdn
}

output "aks_cluster_private_fqdn" {
  description = "The private FQDN of the AKS cluster"
  value       = module.aks.cluster_private_fqdn
}

output "aks_cluster_endpoint" {
  description = "The endpoint of the AKS cluster"
  value       = module.aks.cluster_endpoint
  sensitive   = true
}

output "aks_kube_config" {
  description = "The kube config of the AKS cluster"
  value       = module.aks.kube_config
  sensitive   = true
}

output "aks_oidc_issuer_url" {
  description = "The OIDC issuer URL of the AKS cluster"
  value       = module.aks.cluster_oidc_issuer_url
}

output "aks_workload_identity_client_id" {
  description = "The client ID of the workload identity"
  value       = module.aks.workload_identity_client_id
}

output "materialize_nodepool_name" {
  description = "The name of the Materialize node pool"
  value       = module.materialize_nodepool.nodepool_name
}

output "materialize_nodepool_id" {
  description = "The ID of the Materialize node pool"
  value       = module.materialize_nodepool.nodepool_id
}

# Database outputs
output "database_endpoint" {
  description = "PostgreSQL server endpoint"
  value       = module.database.server_fqdn
}

output "database_name" {
  description = "PostgreSQL server name"
  value       = module.database.server_name
}

output "database_username" {
  description = "PostgreSQL administrator username"
  value       = module.database.administrator_login
  sensitive   = true
}

# Storage outputs
output "storage_account_name" {
  description = "Name of the storage account"
  value       = module.storage.storage_account_name
}

output "storage_primary_blob_endpoint" {
  description = "Primary blob endpoint of the storage account"
  value       = module.storage.primary_blob_endpoint
}

output "storage_container_name" {
  description = "Name of the storage container"
  value       = module.storage.container_name
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
}

# Load balancer outputs
output "console_load_balancer_ip" {
  description = "IP address of the Materialize console's load balancer."
  value       = module.load_balancers.console_load_balancer_ip
}

output "balancerd_load_balancer_ip" {
  description = "IP address of the Materialize balancerd's load balancer."
  value       = module.load_balancers.balancerd_load_balancer_ip
}

# Azure-specific outputs
output "resource_group_name" {
  value = azurerm_resource_group.materialize.name
}

output "external_login_password_mz_system" {
  description = "Password for external login to the Materialize instance"
  value       = random_password.external_login_password_mz_system.result
  sensitive   = true
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
output "ory_database_endpoint" {
  description = "PostgreSQL server endpoint for Ory"
  value       = module.ory_database.server_fqdn
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

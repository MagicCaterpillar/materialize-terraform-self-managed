# Networking outputs
output "network" {
  description = "Network details"
  value = {
    network_id    = module.networking.network_id
    network_name  = module.networking.network_name
    subnets_names = module.networking.subnets_names
  }
}

# Cluster outputs
output "gke_cluster_name" {
  description = "GKE cluster name"
  value       = module.gke.cluster_name
}

output "gke_cluster_endpoint" {
  description = "GKE cluster endpoint"
  value       = module.gke.cluster_endpoint
  sensitive   = true
}

output "gke_cluster_private_endpoint" {
  description = "GKE cluster private endpoint"
  value       = module.gke.cluster_private_endpoint
  sensitive   = true
}

output "gke_cluster_location" {
  description = "GKE cluster location"
  value       = module.gke.cluster_location
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.gke.cluster_ca_certificate
  sensitive   = true
}


output "service_account_email" {
  description = "Service account email for GKE nodes"
  value       = module.gke.service_account_email
}

output "workload_identity_sa_email" {
  description = "The email of the Workload Identity service account"
  value       = module.gke.workload_identity_sa_email
}

output "generic_nodepool_name" {
  description = "Name of the generic node pool"
  value       = module.generic_nodepool.node_pool_name
}

output "generic_nodepool_id" {
  description = "ID of the generic node pool"
  value       = module.generic_nodepool.node_pool_id
}

output "materialize_nodepool_name" {
  description = "Name of the Materialize node pool"
  value       = module.materialize_nodepool.node_pool_name
}

output "materialize_nodepool_id" {
  description = "ID of the Materialize node pool"
  value       = module.materialize_nodepool.node_pool_id
}

# Database outputs
output "database_instance_name" {
  description = "Cloud SQL instance name"
  value       = module.database.instance_name
}

output "database_private_ip" {
  description = "Cloud SQL instance private IP"
  value       = module.database.private_ip
}

output "database_names" {
  description = "List of database names"
  value       = module.database.database_names
}

output "database_users" {
  description = "List of database users with credentials"
  value       = module.database.users
  sensitive   = true
}

# Storage outputs
output "storage" {
  description = "GCS bucket details"
  value = {
    name      = module.storage.bucket_name
    url       = module.storage.bucket_url
    self_link = module.storage.bucket_self_link
  }
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
output "console_load_balancer_ip" {
  description = "IP address of the Materialize console's load balancer."
  value       = module.load_balancers.console_load_balancer_ip
}

output "balancerd_load_balancer_ip" {
  description = "IP address of the Materialize balancerd's load balancer."
  value       = module.load_balancers.balancerd_load_balancer_ip
}

output "external_login_password_mz_system" {
  description = "Password for the external login to the Materialize instance"
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
output "ory_database_instance_name" {
  description = "Cloud SQL instance name for Ory"
  value       = module.ory_database.instance_name
}

output "ory_database_private_ip" {
  description = "Cloud SQL instance private IP for Ory"
  value       = module.ory_database.private_ip
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

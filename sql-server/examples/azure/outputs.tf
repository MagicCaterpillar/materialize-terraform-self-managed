output "namespace" {
  description = "Kubernetes namespace containing the SQL Server resources."
  value       = module.sql_server.namespace
}

output "service_name" {
  description = "Kubernetes Service name. Use as the hostname from within the same cluster."
  value       = module.sql_server.service_name
}

output "service_fqdn" {
  description = "Fully-qualified in-cluster DNS name for SQL Server."
  value       = module.sql_server.service_fqdn
}

output "port" {
  description = "SQL Server TCP port."
  value       = module.sql_server.port
}

output "sa_password" {
  description = "SA password. Sensitive – retrieve with: terraform output -raw sa_password"
  value       = module.sql_server.sa_password
  sensitive   = true
}

output "connection_string" {
  description = "ADO.NET connection string for in-cluster clients. Sensitive."
  value       = module.sql_server.connection_string
  sensitive   = true
}

output "jdbc_connection_string" {
  description = "JDBC connection string for in-cluster clients. Sensitive."
  value       = module.sql_server.jdbc_connection_string
  sensitive   = true
}

output "deployment_name" {
  description = "Kubernetes Deployment name."
  value       = module.sql_server.deployment_name
}

output "pvc_name" {
  description = "PersistentVolumeClaim name. This disk persists independently of the pod."
  value       = module.sql_server.pvc_name
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster SQL Server was deployed to."
  value       = data.azurerm_kubernetes_cluster.target.name
}

output "sql_node_pool_name" {
  description = "Name of the Terraform-managed amd64 node pool when enabled."
  value       = var.create_amd64_node_pool ? azurerm_kubernetes_cluster_node_pool.sql_amd64[0].name : null
}

output "sql_node_selector" {
  description = "Effective node selector used by SQL Server pods."
  value = merge(
    var.node_selector,
    var.force_amd64_scheduling ? { "kubernetes.io/arch" = "amd64" } : {},
    var.create_amd64_node_pool ? { "agentpool" = var.amd64_node_pool_name } : {}
  )
}

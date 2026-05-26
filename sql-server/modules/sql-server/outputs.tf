output "namespace" {
  description = "Kubernetes namespace containing the SQL Server resources."
  value       = kubernetes_namespace.sql_server.metadata[0].name
}

output "service_name" {
  description = "Kubernetes Service name for SQL Server. Use this as the hostname from within the same cluster."
  value       = kubernetes_service.sql_server.metadata[0].name
}

output "service_fqdn" {
  description = "Fully-qualified in-cluster DNS name for the SQL Server service (<name>.<namespace>.svc.cluster.local)."
  value       = "${kubernetes_service.sql_server.metadata[0].name}.${kubernetes_namespace.sql_server.metadata[0].name}.svc.cluster.local"
}

output "port" {
  description = "TCP port SQL Server listens on."
  value       = 1433
}

output "sa_password" {
  description = "SA password (generated or supplied). Treat as a secret."
  value       = local.effective_sa_password
  sensitive   = true
}

output "connection_string" {
  description = "ADO.NET connection string for in-cluster clients (e.g. for configuring Materialize SQL Server source). Treat as a secret."
  value       = "Server=${kubernetes_service.sql_server.metadata[0].name}.${kubernetes_namespace.sql_server.metadata[0].name}.svc.cluster.local,1433;User Id=SA;Password=${local.effective_sa_password};TrustServerCertificate=True;"
  sensitive   = true
}

output "jdbc_connection_string" {
  description = "JDBC connection string for in-cluster clients. Treat as a secret."
  value       = "jdbc:sqlserver://${kubernetes_service.sql_server.metadata[0].name}.${kubernetes_namespace.sql_server.metadata[0].name}.svc.cluster.local:1433;user=SA;password=${local.effective_sa_password};encrypt=true;trustServerCertificate=true;"
  sensitive   = true
}

output "deployment_name" {
  description = "Name of the Kubernetes Deployment managing the SQL Server pod."
  value       = kubernetes_deployment.sql_server.metadata[0].name
}

output "pvc_name" {
  description = "Name of the PersistentVolumeClaim holding SQL Server data. This disk persists independently of the pod."
  value       = kubernetes_persistent_volume_claim.sql_data.metadata[0].name
}

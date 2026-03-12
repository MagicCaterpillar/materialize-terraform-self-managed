output "server_id" {
  description = "The ID of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.postgres.id
}

output "server_name" {
  description = "The name of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.postgres.name
}

output "server_fqdn" {
  description = "The FQDN of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.postgres.fqdn
}

output "administrator_login" {
  description = "The administrator login name"
  value       = azurerm_postgresql_flexible_server.postgres.administrator_login
}

output "administrator_password" {
  description = "The administrator password (generated if not provided)"
  value       = var.administrator_password != null && var.administrator_password != "" ? var.administrator_password : try(random_password.admin_password[0].result, null)
  sensitive   = true
}

output "databases" {
  description = "Map of created databases"
  value = {
    for db_name, db in azurerm_postgresql_flexible_server_database.databases : db_name => {
      name      = db.name
      charset   = db.charset
      collation = db.collation
    }
  }
}

output "database_names" {
  description = "List of database names"
  value       = [for db in azurerm_postgresql_flexible_server_database.databases : db.name]
}

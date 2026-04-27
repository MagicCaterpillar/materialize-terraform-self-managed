## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 3.75.0, < 4.55.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0, < 3.9.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 3.75.0, < 4.55.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0, < 3.9.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_postgresql_flexible_server.postgres](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server) | resource |
| [azurerm_postgresql_flexible_server_database.databases](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server_database) | resource |
| [random_password.admin_password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_administrator_login"></a> [administrator\_login](#input\_administrator\_login) | The administrator login name for the PostgreSQL server | `string` | n/a | yes |
| <a name="input_administrator_password"></a> [administrator\_password](#input\_administrator\_password) | The administrator password for the PostgreSQL server. If not provided, a random password will be generated. | `string` | `null` | no |
| <a name="input_backup_retention_days"></a> [backup\_retention\_days](#input\_backup\_retention\_days) | The number of days to retain backups | `number` | `7` | no |
| <a name="input_databases"></a> [databases](#input\_databases) | List of databases to create | <pre>list(object({<br/>    name      = string<br/>    charset   = optional(string, "UTF8")<br/>    collation = optional(string, "en_US.utf8")<br/>  }))</pre> | n/a | yes |
| <a name="input_location"></a> [location](#input\_location) | The location where resources will be created | `string` | n/a | yes |
| <a name="input_postgres_version"></a> [postgres\_version](#input\_postgres\_version) | The PostgreSQL version | `string` | n/a | yes |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Prefix to be used for resource names | `string` | n/a | yes |
| <a name="input_private_dns_zone_id"></a> [private\_dns\_zone\_id](#input\_private\_dns\_zone\_id) | The ID of the private DNS zone | `string` | n/a | yes |
| <a name="input_public_network_access_enabled"></a> [public\_network\_access\_enabled](#input\_public\_network\_access\_enabled) | Whether public network access is enabled | `bool` | `false` | no |
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | The name of the resource group | `string` | n/a | yes |
| <a name="input_sku_name"></a> [sku\_name](#input\_sku\_name) | The SKU name for the PostgreSQL server, sku denotes the size of postgres server | `string` | n/a | yes |
| <a name="input_storage_mb"></a> [storage\_mb](#input\_storage\_mb) | The storage capacity in MB | `number` | `32768` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | The ID of the subnet for PostgreSQL | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_administrator_login"></a> [administrator\_login](#output\_administrator\_login) | The administrator login name |
| <a name="output_administrator_password"></a> [administrator\_password](#output\_administrator\_password) | The administrator password (generated if not provided) |
| <a name="output_database_names"></a> [database\_names](#output\_database\_names) | List of database names |
| <a name="output_databases"></a> [databases](#output\_databases) | Map of created databases |
| <a name="output_server_fqdn"></a> [server\_fqdn](#output\_server\_fqdn) | The FQDN of the PostgreSQL server |
| <a name="output_server_id"></a> [server\_id](#output\_server\_id) | The ID of the PostgreSQL server |
| <a name="output_server_name"></a> [server\_name](#output\_server\_name) | The name of the PostgreSQL server |

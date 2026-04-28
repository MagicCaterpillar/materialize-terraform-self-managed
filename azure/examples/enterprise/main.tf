provider "azurerm" {
  # Set the Azure subscription ID here or use the AZURE_SUBSCRIPTION_ID environment variable
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
    }
  }
}

provider "kubernetes" {
  host                   = module.aks.cluster_endpoint
  client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
  client_key             = base64decode(module.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = module.aks.cluster_endpoint
    client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
    client_key             = base64decode(module.aks.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = module.aks.cluster_endpoint
  client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
  client_key             = base64decode(module.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)

  load_config_file = false
}


locals {
  vnet_config = {
    address_space                      = "20.0.0.0/16"
    aks_subnet_cidr                    = "20.0.0.0/20"
    postgres_subnet_cidr               = "20.0.16.0/24"
    enable_api_server_vnet_integration = true
    api_server_subnet_cidr             = "20.0.32.0/27" # keeping atleast 32 IPs reserved for API server and related services used in delegation might reduce it later.
  }

  aks_config = {
    kubernetes_version         = "1.33"
    service_cidr               = "20.1.0.0/16"
    enable_azure_monitor       = false
    log_analytics_workspace_id = null
  }

  node_pool_config = {
    vm_size              = "Standard_E4pds_v6"
    auto_scaling_enabled = true
    min_nodes            = 2
    max_nodes            = 5
    node_count           = null
    disk_size_gb         = 100
    swap_enabled         = true
  }

  database_config = {
    sku_name                      = "GP_Standard_D2s_v3"
    postgres_version              = "15"
    storage_mb                    = 32768
    backup_retention_days         = 7
    administrator_login           = "materialize"
    administrator_password        = null # Will generate random password
    database_name                 = "materialize"
    public_network_access_enabled = false
  }

  # Ory database configuration (separate Postgres instance)
  ory_database_config = {
    sku_name                      = "B_Standard_B1ms"
    postgres_version              = "15"
    storage_mb                    = 32768
    backup_retention_days         = 7
    administrator_login           = "oryadmin"
    administrator_password        = null # Will generate random password
    public_network_access_enabled = false
  }

  storage_container_name = "materialize"

  database_statement_timeout = "15min"

  metadata_backend_url = format(
    "postgres://%s:%s@%s/%s?sslmode=require&options=-c%%20statement_timeout%%3D%s",
    module.database.administrator_login,
    urlencode(module.database.administrator_password),
    module.database.server_fqdn,
    local.database_config.database_name,
    local.database_statement_timeout
  )

  persist_backend_url = format(
    "%s%s",
    module.storage.primary_blob_endpoint,
    module.storage.container_name,
  )

  materialize_instance_namespace = "materialize-environment"
  materialize_instance_name      = "main"

  # Common node scheduling configuration
  generic_node_labels = {
    "workload" = "generic"
  }

  materialize_node_labels = {
    "workload" = "materialize-instance"
  }

  materialize_node_taints = [
    {
      key    = "materialize.cloud/workload"
      value  = "materialize-instance"
      effect = "NoSchedule"
    }
  ]

  materialize_tolerations = [
    {
      key      = "materialize.cloud/workload"
      value    = "materialize-instance"
      operator = "Equal"
      effect   = "NoSchedule"
    }
  ]

  # https://learn.microsoft.com/en-us/azure/aks/concepts-storage#storage-classes
  storage_class = "managed-csi"

  # Ory database DSNs
  ory_kratos_dsn = format(
    "postgres://%s:%s@%s/%s?sslmode=require",
    module.ory_database.administrator_login,
    urlencode(module.ory_database.administrator_password),
    module.ory_database.server_fqdn,
    "kratos"
  )

  ory_hydra_dsn = format(
    "postgres://%s:%s@%s/%s?sslmode=require",
    module.ory_database.administrator_login,
    urlencode(module.ory_database.administrator_password),
    module.ory_database.server_fqdn,
    "hydra"
  )

  # External URLs for Ory components. These are what the browser (and Materialize, for
  # issuer matching) sees. Customer-provided hostnames resolve to the LoadBalancer IPs
  # and are terminated by TLS certs issued by cert-manager.
  hydra_external_url  = "https://${var.ory_hydra_hostname}/"
  ui_external_url     = "https://${var.ory_ui_hostname}"
  kratos_external_url = "https://${var.ory_kratos_hostname}"

  # Parent domain shared by all Ory hostnames (the part after the first label).
  # Used as the cookie domain so flow/session cookies are shared across
  # sibling subdomains (Kratos, selfservice UI, Hydra).
  cookie_parent_domain = join(".", slice(split(".", var.ory_kratos_hostname), 1, length(split(".", var.ory_kratos_hostname))))

  # cert-manager ClusterIssuer used for browser-facing TLS certs (Materialize
  # console/balancerd, Hydra, Kratos, selfservice UI). Defaults to the built-in
  # self-signed issuer; override via var.cert_issuer_ref to plug in a real
  # issuer (corporate CA, Let's Encrypt, etc.). See the README for a Let's
  # Encrypt + Cloudflare DNS-01 example.
  cert_issuer = var.cert_issuer_ref != null ? var.cert_issuer_ref : {
    name = module.self_signed_cluster_issuer.issuer_name
    kind = "ClusterIssuer"
  }

  # Internal cert issuer for the Materialize CR's internalCertificateSpec, which
  # has cluster.local SANs that public ACME issuers (Let's Encrypt) can't sign.
  # Always uses the self-signed cluster issuer regardless of cert_issuer_ref.
  internal_cert_issuer = {
    name = module.self_signed_cluster_issuer.issuer_name
    kind = "ClusterIssuer"
  }
}


resource "azurerm_resource_group" "materialize" {
  name     = var.resource_group_name
  location = var.location
}


module "networking" {
  source = "../../modules/networking"

  resource_group_name                = azurerm_resource_group.materialize.name
  location                           = var.location
  prefix                             = var.name_prefix
  vnet_address_space                 = local.vnet_config.address_space
  aks_subnet_cidr                    = local.vnet_config.aks_subnet_cidr
  postgres_subnet_cidr               = local.vnet_config.postgres_subnet_cidr
  enable_api_server_vnet_integration = local.vnet_config.enable_api_server_vnet_integration
  api_server_subnet_cidr             = local.vnet_config.api_server_subnet_cidr

  tags = var.tags

  depends_on = [azurerm_resource_group.materialize]
}

# AKS Cluster with Default Node Pool
module "aks" {
  source = "../../modules/aks"

  resource_group_name = azurerm_resource_group.materialize.name
  kubernetes_version  = local.aks_config.kubernetes_version
  service_cidr        = local.aks_config.service_cidr
  location            = var.location
  prefix              = var.name_prefix
  vnet_name           = module.networking.vnet_name
  subnet_name         = module.networking.aks_subnet_name
  subnet_id           = module.networking.aks_subnet_id

  enable_api_server_vnet_integration = local.vnet_config.enable_api_server_vnet_integration
  k8s_apiserver_authorized_networks  = concat(var.k8s_apiserver_authorized_networks, ["${module.networking.nat_gateway_public_ip}/32"])
  api_server_subnet_id               = module.networking.api_server_subnet_id

  # Default node pool with autoscaling (runs all workloads except Materialize)
  default_node_pool_vm_size             = "Standard_D4pds_v6"
  default_node_pool_enable_auto_scaling = true
  default_node_pool_min_count           = 2
  default_node_pool_max_count           = 5
  default_node_pool_node_labels         = local.generic_node_labels

  # Optional: Enable monitoring
  enable_azure_monitor       = local.aks_config.enable_azure_monitor
  log_analytics_workspace_id = local.aks_config.log_analytics_workspace_id

  tags = var.tags

  depends_on = [azurerm_resource_group.materialize]
}

# Materialize-dedicated node pool with taints (via labels on Azure)
module "materialize_nodepool" {
  source = "../../modules/nodepool"

  prefix     = var.name_prefix
  cluster_id = module.aks.cluster_id
  subnet_id  = module.networking.aks_subnet_id

  # Workload-specific configuration
  autoscaling_config = {
    enabled    = local.node_pool_config.auto_scaling_enabled
    min_nodes  = local.node_pool_config.min_nodes
    max_nodes  = local.node_pool_config.max_nodes
    node_count = local.node_pool_config.node_count
  }

  vm_size      = local.node_pool_config.vm_size
  disk_size_gb = local.node_pool_config.disk_size_gb
  swap_enabled = local.node_pool_config.swap_enabled

  labels = local.materialize_node_labels

  # Materialize-specific taint to isolate workloads
  # https://github.com/Azure/AKS/issues/2934
  # Note: Once applied, these cannot be manually removed due to AKS webhook restrictions
  node_taints = local.materialize_node_taints

  tags = var.tags

  depends_on = [azurerm_resource_group.materialize]
}


module "database" {
  source = "../../modules/database"

  depends_on = [module.networking]

  # Database configuration using new structure
  databases = [
    {
      name      = local.database_config.database_name
      charset   = "UTF8"
      collation = "en_US.utf8"
    }
  ]

  # Administrator configuration
  administrator_login = local.database_config.administrator_login

  # Infrastructure configuration
  resource_group_name = azurerm_resource_group.materialize.name
  location            = var.location
  prefix              = var.name_prefix
  subnet_id           = module.networking.postgres_subnet_id
  private_dns_zone_id = module.networking.private_dns_zone_id

  # Database server configuration
  sku_name                      = local.database_config.sku_name
  postgres_version              = local.database_config.postgres_version
  storage_mb                    = local.database_config.storage_mb
  backup_retention_days         = local.database_config.backup_retention_days
  public_network_access_enabled = local.database_config.public_network_access_enabled

  tags = var.tags
}

# Separate Postgres instance for Ory (Kratos + Hydra)
module "ory_database" {
  source = "../../modules/database"

  depends_on = [module.networking]

  databases = [
    {
      name      = "kratos"
      charset   = "UTF8"
      collation = "en_US.utf8"
    },
    {
      name      = "hydra"
      charset   = "UTF8"
      collation = "en_US.utf8"
    }
  ]

  administrator_login = local.ory_database_config.administrator_login

  resource_group_name = azurerm_resource_group.materialize.name
  location            = var.location
  prefix              = "${var.name_prefix}-ory"
  subnet_id           = module.networking.postgres_subnet_id
  private_dns_zone_id = module.networking.private_dns_zone_id

  sku_name                      = local.ory_database_config.sku_name
  postgres_version              = local.ory_database_config.postgres_version
  storage_mb                    = local.ory_database_config.storage_mb
  backup_retention_days         = local.ory_database_config.backup_retention_days
  public_network_access_enabled = local.ory_database_config.public_network_access_enabled

  tags = var.tags
}

# Enable PostgreSQL extensions required by Ory Kratos migrations (pg_trgm + btree_gin for GIN indexes)
resource "azurerm_postgresql_flexible_server_configuration" "ory_extensions" {
  name      = "azure.extensions"
  server_id = module.ory_database.server_id
  value     = "btree_gin,pg_trgm,uuid-ossp"

  depends_on = [module.ory_database]
}

module "storage" {
  source = "../../modules/storage"

  resource_group_name            = azurerm_resource_group.materialize.name
  location                       = var.location
  prefix                         = var.name_prefix
  workload_identity_principal_id = module.aks.workload_identity_principal_id
  subnets                        = [module.networking.aks_subnet_id]
  container_name                 = local.storage_container_name

  # Workload identity federation configuration
  workload_identity_id      = module.aks.workload_identity_id
  oidc_issuer_url           = module.aks.cluster_oidc_issuer_url
  service_account_namespace = local.materialize_instance_namespace
  service_account_name      = local.materialize_instance_name

  storage_account_tags = var.tags

  depends_on = [azurerm_resource_group.materialize]
}

resource "random_password" "external_login_password_mz_system" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Deploy custom CoreDNS with TTL 0 (AKS's coredns doesn't support disabling caching)
module "coredns" {
  source          = "../../../kubernetes/modules/coredns"
  node_selector   = local.generic_node_labels
  kubeconfig_data = module.aks.kube_config_raw
  depends_on = [
    module.aks,
    module.networking,
  ]
}

module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  node_selector = local.generic_node_labels

  depends_on = [
    module.aks,
    module.networking,
    module.coredns,
  ]
}

# Always-created self-signed cluster issuer. Used for the internal mTLS cert
# spec (which has *.cluster.local SANs that public ACME issuers reject) and as
# the default for the browser-facing certs when var.cert_issuer_ref is null.
module "self_signed_cluster_issuer" {
  source = "../../../kubernetes/modules/self-signed-cluster-issuer"

  name_prefix = var.name_prefix

  depends_on = [
    module.cert_manager,
  ]
}

module "operator" {
  source = "../../modules/operator"

  name_prefix = var.name_prefix
  location    = var.location

  instance_pod_tolerations = local.materialize_tolerations
  instance_node_selector   = local.materialize_node_labels

  # node selector for operator and metrics-server workloads
  operator_node_selector = local.generic_node_labels

  # Enable Prometheus scrape annotations when observability is enabled
  helm_values = var.enable_observability ? {
    observability = {
      enabled = true
      prometheus = {
        scrapeAnnotations = {
          enabled = true
        }
      }
    }
  } : {}

  depends_on = [
    module.aks,
    module.database,
    module.storage,
    module.coredns,
  ]
}

module "prometheus" {
  count  = var.enable_observability ? 1 : 0
  source = "../../../kubernetes/modules/prometheus"

  namespace        = "monitoring"
  create_namespace = false # operator creates the "monitoring" namespace
  node_selector    = local.generic_node_labels
  storage_class    = local.storage_class

  depends_on = [
    module.operator,
    module.aks,
    module.coredns,
  ]
}

module "grafana" {
  count  = var.enable_observability ? 1 : 0
  source = "../../../kubernetes/modules/grafana"

  namespace     = "monitoring"
  storage_class = local.storage_class
  # operator creates the "monitoring" namespace
  create_namespace = false
  prometheus_url   = module.prometheus[0].prometheus_url
  node_selector    = local.generic_node_labels

  depends_on = [
    module.prometheus,
  ]
}

module "materialize_instance" {
  source               = "../../../kubernetes/modules/materialize-instance"
  instance_name        = local.materialize_instance_name
  instance_namespace   = local.materialize_instance_namespace
  metadata_backend_url = local.metadata_backend_url
  persist_backend_url  = local.persist_backend_url

  # Use OIDC authentication via Ory Hydra. The external_login_password is still required
  # as a fallback for the mz_system admin user.
  authenticator_kind                = "Oidc"
  external_login_password_mz_system = random_password.external_login_password_mz_system.result

  # Azure workload identity annotations for service account
  service_account_annotations = {
    "azure.workload.identity/client-id" = module.aks.workload_identity_client_id
  }
  pod_labels = {
    "azure.workload.identity/use" = "true"
  }

  license_key = var.license_key

  issuer_ref = local.cert_issuer
  # Internal mTLS uses cluster.local SANs which a public ACME issuer can't sign,
  # so always route the internal cert spec through the private (self-signed) CA.
  internal_issuer_ref = local.internal_cert_issuer

  # Include the external console hostname in the cert so browsers accept it.
  console_extra_dns_names   = [var.materialize_console_hostname]
  balancerd_extra_dns_names = [var.materialize_console_hostname]

  # OIDC configuration — points Materialize at Hydra for JWT validation.
  # client_id comes from the Hydra Maester-generated secret (Hydra Maester auto-
  # generates a UUID client_id; the installed CRD version doesn't support setting
  # it explicitly).
  # See: https://materialize.com/docs/security/self-managed/sso/
  system_parameters = {
    oidc_issuer               = local.hydra_external_url
    oidc_audience             = jsonencode([data.kubernetes_secret_v1.oauth2_client.data["CLIENT_ID"]])
    oidc_authentication_claim = "email"
    console_oidc_client_id    = data.kubernetes_secret_v1.oauth2_client.data["CLIENT_ID"]
    console_oidc_scopes       = "openid email"
  }

  depends_on = [
    module.aks,
    module.database,
    module.storage,
    module.networking,
    module.self_signed_cluster_issuer,
    module.operator,
    module.materialize_nodepool,
    module.coredns,
    module.ory_hydra,
    kubectl_manifest.materialize_oauth2_client,
  ]
}

module "load_balancers" {
  source = "../../modules/load_balancers"

  instance_name       = local.materialize_instance_name
  namespace           = local.materialize_instance_namespace
  resource_id         = module.materialize_instance.instance_resource_id
  internal            = var.internal_load_balancer
  ingress_cidr_blocks = var.internal_load_balancer ? null : var.ingress_cidr_blocks

  depends_on = [
    module.materialize_instance,
  ]
}

# Allow Materialize pods to reach Ory (Hydra OIDC discovery + JWKS).
resource "kubernetes_network_policy_v1" "materialize_to_ory_egress" {
  metadata {
    name      = "allow-ory-egress"
    namespace = local.materialize_instance_namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ory"
          }
        }
      }
    }
  }

  depends_on = [module.materialize_instance]
}

# Allow Ory pods to receive traffic from Materialize, within the ory namespace,
# and from external LoadBalancers (the Hydra public API and selfservice UI are
# browser-facing and must be reachable from clients outside the cluster).
resource "kubernetes_network_policy_v1" "ory_from_materialize_ingress" {
  metadata {
    name      = "allow-materialize-ingress"
    namespace = "ory"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    # Allow full traffic from Materialize and within the ory namespace.
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.materialize_instance_namespace
          }
        }
      }

      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ory"
          }
        }
      }
    }

    # Allow external traffic (from LoadBalancers) only to Hydra public (4444),
    # Kratos public (4433), and the selfservice UI (3000). Admin ports stay internal.
    ingress {
      from {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }
      ports {
        protocol = "TCP"
        port     = 4444
      }
      ports {
        protocol = "TCP"
        port     = 4433
      }
      ports {
        protocol = "TCP"
        port     = 3000
      }
    }
  }

  depends_on = [kubernetes_namespace.ory]
}

# -----------------------------------------------------------------------------
# Ory: Identity & OAuth2 (Kratos + Hydra)
# -----------------------------------------------------------------------------

# TODO: Update auth mechanism once Materialize private registry is set up.
resource "kubernetes_namespace" "ory" {
  metadata {
    name = "ory"
  }

  depends_on = [module.aks]
}

resource "kubernetes_secret" "ory_oel_registry" {
  metadata {
    name      = "ory-oel-registry"
    namespace = kubernetes_namespace.ory.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "europe-docker.pkg.dev" = {
          auth = base64encode("_json_key:${file(var.ory_oel_key_file)}")
        }
      }
    })
  }
}

module "ory_kratos" {
  source = "../../../kubernetes/modules/ory-kratos"

  namespace        = "ory"
  create_namespace = false
  dsn              = local.ory_kratos_dsn

  # OEL image — registry must be part of repository (Ory Helm chart ignores image.registry)
  image_repository   = "${var.ory_oel_registry}/ory-enterprise-kratos/kratos-oel"
  image_tag          = var.ory_oel_image_tag
  image_pull_secrets = ["ory-oel-registry"]

  # Serve TLS directly in the Kratos pod using cert-manager-issued certs.
  tls_cert_secret_name = "kratos-tls"

  node_selector = local.generic_node_labels

  # Kratos requires at least one identity schema and a default browser return URL
  identity_schemas = {
    "identity.default.schema.json" = jsonencode({
      "$id"     = "https://schemas.ory.sh/presets/kratos/identity.basic.schema.json"
      "$schema" = "http://json-schema.org/draft-07/schema#"
      title     = "Default Identity Schema"
      type      = "object"
      properties = {
        traits = {
          type = "object"
          properties = {
            email = {
              type   = "string"
              format = "email"
              title  = "Email"
              "ory.sh/kratos" = {
                credentials = {
                  password = { identifier = true }
                }
                recovery     = { via = "email" }
                verification = { via = "email" }
              }
            }
          }
          required = ["email"]
        }
      }
    })
  }

  helm_values = {
    kratos = {
      config = {
        serve = {
          # base_url is what Kratos uses when rendering links for the browser
          # (redirects, form action URLs, etc.). Must be a browser-reachable URL.
          public = {
            base_url = local.kratos_external_url
          }
        }
        # Set cookie domain to the parent so cookies work across sibling subdomains
        # (the selfservice UI sends cookies that were set by Kratos and vice versa).
        cookies = {
          domain    = local.cookie_parent_domain
          same_site = "Lax"
        }
        session = {
          cookie = {
            domain    = local.cookie_parent_domain
            same_site = "Lax"
          }
        }
        # Tell Kratos where Hydra's admin API is. Required for Kratos to process
        # login_challenge query parameters that come from Hydra during OIDC flows.
        oauth2_provider = {
          url = "http://hydra-admin.ory.svc.cluster.local:4445"
        }
        selfservice = {
          default_browser_return_url = local.ui_external_url
          # Point Kratos's user-facing flows at the selfservice UI.
          flows = {
            login        = { ui_url = "${local.ui_external_url}/login" }
            registration = { ui_url = "${local.ui_external_url}/registration" }
            recovery     = { ui_url = "${local.ui_external_url}/recovery" }
            verification = { ui_url = "${local.ui_external_url}/verification" }
            settings     = { ui_url = "${local.ui_external_url}/settings" }
            error        = { ui_url = "${local.ui_external_url}/error" }
            logout       = { after = { default_browser_return_url = local.ui_external_url } }
          }
        }
        identity = {
          default_schema_id = "default"
          schemas = [
            {
              id  = "default"
              url = "file:///etc/config/identity.default.schema.json"
            }
          ]
        }
      }
    }
  }

  depends_on = [
    module.aks,
    module.ory_database,
    module.coredns,
    azurerm_postgresql_flexible_server_configuration.ory_extensions,
    kubernetes_secret.ory_oel_registry,
    kubernetes_namespace.ory,
    kubectl_manifest.kratos_certificate,
  ]
}

# TLS certificates for Hydra and the selfservice UI, issued by the existing
# self-signed ClusterIssuer (same one used for Materialize internal TLS).
resource "kubectl_manifest" "hydra_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "hydra-tls"
      namespace = "ory"
    }
    spec = {
      secretName = "hydra-tls"
      # The external hostname covers browser traffic. The cluster-internal SAN
      # is only included with the default self-signed issuer (which can sign
      # cluster.local). When var.cert_issuer_ref is set we assume the customer
      # may be using a public ACME issuer that rejects .cluster.local, so we
      # drop the SAN and route in-cluster clients to Hydra via the public
      # hostname (hairpin NAT through the LB; TLS still validates).
      dnsNames = concat(
        [var.ory_hydra_hostname],
        var.cert_issuer_ref != null ? [] : ["hydra-public.ory.svc.cluster.local"],
      )
      issuerRef = local.cert_issuer
    }
  })

  depends_on = [
    module.self_signed_cluster_issuer,
    kubernetes_namespace.ory,
  ]
}

resource "kubectl_manifest" "kratos_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "kratos-tls"
      namespace = "ory"
    }
    spec = {
      secretName = "kratos-tls"
      # See the equivalent comment on hydra_certificate above. Same trade-off.
      dnsNames = concat(
        [var.ory_kratos_hostname],
        var.cert_issuer_ref != null ? [] : ["kratos-public.ory.svc.cluster.local"],
      )
      issuerRef = local.cert_issuer
    }
  })

  depends_on = [
    module.self_signed_cluster_issuer,
    kubernetes_namespace.ory,
  ]
}

resource "kubectl_manifest" "ui_certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "ory-selfservice-ui-tls"
      namespace = "ory"
    }
    spec = {
      secretName = "ory-selfservice-ui-tls"
      dnsNames   = [var.ory_ui_hostname]
      issuerRef  = local.cert_issuer
    }
  })

  depends_on = [
    module.self_signed_cluster_issuer,
    kubernetes_namespace.ory,
  ]
}

module "ory_hydra" {
  source = "../../../kubernetes/modules/ory-hydra"

  namespace        = "ory"
  create_namespace = false

  dsn        = local.ory_hydra_dsn
  issuer_url = local.hydra_external_url

  # OEL image — registry must be part of repository (Ory Helm chart ignores image.registry)
  image_repository   = "${var.ory_oel_registry}/ory-enterprise/hydra-oel"
  image_tag          = var.ory_oel_image_tag
  image_pull_secrets = ["ory-oel-registry"]

  # Serve TLS directly in the Hydra pod using cert-manager-issued certs.
  tls_cert_secret_name = "hydra-tls"

  # Allow the Materialize console to call Hydra's OIDC endpoints from the browser.
  cors_allowed_origins = ["https://${var.materialize_console_hostname}"]

  # Browser redirects to the selfservice UI for login/consent (external HTTPS URL).
  login_url   = "${local.ui_external_url}/login"
  consent_url = "${local.ui_external_url}/consent"
  logout_url  = "${local.ui_external_url}/logout"

  helm_values = {
    hydra = {
      config = {
        # Issue JWT access tokens so Materialize can validate them via JWKS.
        strategies = {
          access_token = "jwt"
        }
      }
    }
  }

  node_selector = local.generic_node_labels

  depends_on = [
    module.aks,
    module.ory_database,
    module.ory_kratos,
    module.coredns,
    azurerm_postgresql_flexible_server_configuration.ory_extensions,
    kubernetes_secret.ory_oel_registry,
    kubectl_manifest.hydra_certificate,
  ]
}

# Login + consent UI that sits between Hydra and Kratos.
# Without this, Hydra has no way to authenticate users or collect consent.
module "ory_selfservice_ui" {
  source = "../../../kubernetes/modules/ory-selfservice-ui"

  namespace = "ory"
  # Server-side calls from the UI pod to Kratos's public API. With the default
  # self-signed issuer the cert covers the cluster service URL, so we use it
  # directly. With var.cert_issuer_ref set the cert may only have the external
  # hostname, so we route through it (resolves to the LB IP via public DNS and
  # hairpins back into the cluster).
  kratos_public_url = var.cert_issuer_ref != null ? local.kratos_external_url : module.ory_kratos.public_url
  kratos_admin_url  = module.ory_kratos.admin_url
  # Browser-facing Kratos URL (used when the UI returns redirects or form actions).
  kratos_browser_url = local.kratos_external_url
  hydra_admin_url    = "http://hydra-admin.ory.svc.cluster.local:4445"

  # Serve TLS directly using cert-manager-issued certs.
  tls_cert_secret_name = "ory-selfservice-ui-tls"

  node_selector = local.generic_node_labels

  depends_on = [
    module.ory_kratos,
    module.coredns,
    kubectl_manifest.ui_certificate,
  ]
}

# External LoadBalancer for Kratos's public API. Kratos returns browser-facing URLs
# that redirect here (e.g., form submissions, verification links).
# The admin port (4434) is intentionally NOT exposed — only cluster-internal access.
resource "kubernetes_service_v1" "kratos_public_lb" {
  metadata {
    name      = "kratos-public-lb"
    namespace = "ory"
    annotations = var.internal_load_balancer ? {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    } : {}
  }

  spec {
    type = "LoadBalancer"

    selector = {
      "app.kubernetes.io/name"     = "kratos"
      "app.kubernetes.io/instance" = "kratos"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 4433
      protocol    = "TCP"
    }
  }

  depends_on = [module.ory_kratos]
}

# External LoadBalancer for Hydra's public OAuth2/OIDC endpoints.
# The admin port (4445) is intentionally NOT exposed — only cluster-internal access.
resource "kubernetes_service_v1" "hydra_public_lb" {
  metadata {
    name      = "hydra-public-lb"
    namespace = "ory"
    annotations = var.internal_load_balancer ? {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    } : {}
  }

  spec {
    type = "LoadBalancer"

    selector = {
      "app.kubernetes.io/name"     = "hydra"
      "app.kubernetes.io/instance" = "hydra"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 4444
      protocol    = "TCP"
    }
  }

  depends_on = [module.ory_hydra]
}

# External LoadBalancer for the Materialize console on port 443 (the console
# redirects away from non-canonical ports, so we need HTTPS on 443 externally).
resource "kubernetes_service_v1" "console_lb_443" {
  metadata {
    name      = "${local.materialize_instance_name}-console-https"
    namespace = local.materialize_instance_namespace
    annotations = var.internal_load_balancer ? {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    } : {}
  }

  spec {
    type = "LoadBalancer"

    selector = {
      "materialize.cloud/app"                    = "console"
      "materialize.cloud/mz-resource-id"         = module.materialize_instance.instance_resource_id
      "materialize.cloud/organization-name"      = local.materialize_instance_name
      "materialize.cloud/organization-namespace" = local.materialize_instance_namespace
    }

    port {
      name        = "https"
      port        = 443
      target_port = 8080
      protocol    = "TCP"
    }
  }

  depends_on = [module.materialize_instance]
}

# External LoadBalancer for the selfservice UI (browser-facing login/consent).
resource "kubernetes_service_v1" "ui_lb" {
  metadata {
    name      = "ory-selfservice-ui-lb"
    namespace = "ory"
    annotations = var.internal_load_balancer ? {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
    } : {}
  }

  spec {
    type = "LoadBalancer"

    selector = {
      "app.kubernetes.io/name"     = "kratos-selfservice-ui-node"
      "app.kubernetes.io/instance" = module.ory_selfservice_ui.service_name
    }

    port {
      name        = "https"
      port        = 443
      target_port = module.ory_selfservice_ui.port
      protocol    = "TCP"
    }
  }

  depends_on = [module.ory_selfservice_ui]
}

# Register an OAuth2 client in Hydra for Materialize.
# Hydra Maester (enabled by default in the ory-hydra module) watches for these CRDs
# and creates/manages the OAuth2 client via Hydra's admin API.
# Read the OAuth2 client credentials after Hydra Maester populates the secret.
# This lets the Materialize system parameters reference the auto-generated client_id.
data "kubernetes_secret_v1" "oauth2_client" {
  metadata {
    name      = "materialize-oauth2-client"
    namespace = "ory"
  }

  depends_on = [kubectl_manifest.materialize_oauth2_client]
}

resource "kubectl_manifest" "materialize_oauth2_client" {
  yaml_body = yamlencode({
    apiVersion = "hydra.ory.sh/v1alpha1"
    kind       = "OAuth2Client"
    metadata = {
      name      = "materialize"
      namespace = module.ory_hydra.namespace
    }
    spec = {
      clientName = "Materialize"
      grantTypes = [
        "authorization_code",
        "refresh_token",
      ]
      responseTypes = ["code", "id_token"]
      scope         = "openid profile email offline"
      audience      = ["materialize"]
      redirectUris  = ["https://${var.materialize_console_hostname}/auth/callback"]
      # Public client (SPA) — no client secret; the Materialize console uses PKCE
      # to exchange the authorization code for tokens.
      secretName              = "materialize-oauth2-client"
      tokenEndpointAuthMethod = "none"
    }
  })

  depends_on = [module.ory_hydra]
}

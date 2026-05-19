# =============================================================================
# GCP Migration Configuration
# =============================================================================
#
# This configuration is designed to accept Terraform state migrated from the
# old monolithic GCP module (gcp-old/). Resources that cannot safely use the
# new modules (due to breaking changes) are defined inline to preserve exact
# resource configurations.
#
# INLINE (preserves old config, avoids recreation):
#   - Networking: VPC, subnet, route, VPC peering
#   - GKE: cluster, service accounts, workload identity binding
#   - System node pool: from old GKE module
#   - Database: Cloud SQL instance, database, user
#
# MODULES (compatible structure):
#   - materialize_nodepool: gcp/modules/nodepool
#   - storage: gcp/modules/storage
#   - cert_manager: kubernetes/modules/cert-manager
#   - self_signed_cluster_issuer: kubernetes/modules/self-signed-cluster-issuer
#   - operator: gcp/modules/operator
#   - materialize_instance: kubernetes/modules/materialize-instance
#   - load_balancers: gcp/modules/load_balancers
#
# =============================================================================

# =============================================================================
# Providers
# =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region
  # NOTE: The old module did NOT use default_labels on the provider.
  # Adding it here would cause unnecessary label diffs on resources that
  # never had labels (VPC, subnet, route, etc.). Labels are applied
  # explicitly on resources that need them (Cloud SQL, GCS, node pools).
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

# lazy_load = true lets alekc/kubectl v2.4.0+ defer kubeconfig resolution
# (which is strict at provider-configure since v2.3.0) until first use. Without
# it, same-root cluster-plus-manifests applies fail at plan with an empty REST
# config because the cluster resource's outputs are unknown before it exists.
# See: https://registry.terraform.io/providers/alekc/kubectl/latest/docs#troubleshooting
provider "kubectl" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)

  load_config_file = false
  lazy_load        = true
}

# =============================================================================
# Locals
# =============================================================================

locals {
  # Matches the old module's common_labels pattern exactly.
  # Changing labels on GKE node pools would cause node rotation.
  common_labels = merge(var.labels, {
    managed_by = "terraform"
    module     = "materialize"
  })

  # System node pool labels (matches old GKE module)
  system_node_labels = merge(
    local.common_labels,
    {
      "workload" = "system"
    }
  )

  # Backend URL construction (matches old module format)
  encoded_endpoint = urlencode("https://storage.googleapis.com")
  encoded_secret   = urlencode(module.storage.hmac_secret)

  metadata_backend_url = format(
    "postgres://%s:%s@%s:5432/%s?sslmode=disable",
    var.database_username,
    urlencode(var.database_password),
    google_sql_database_instance.materialize.private_ip_address,
    var.database_name
  )

  persist_backend_url = format(
    "s3://%s:%s@%s/materialize?endpoint=%s&region=%s",
    module.storage.hmac_access_id,
    local.encoded_secret,
    module.storage.bucket_name,
    local.encoded_endpoint,
    var.region
  )
}

# =============================================================================
# INLINE: Networking
# =============================================================================
# Preserves the exact old networking module resources.
# The new networking module uses terraform-google-modules (different state
# paths and adds Cloud NAT), which would force resource recreation.
# =============================================================================

resource "google_compute_network" "vpc" {
  name                    = "${var.prefix}-network"
  auto_create_subnetworks = false
  project                 = var.project_id

  lifecycle {
    create_before_destroy = true
    prevent_destroy       = false
  }
}

resource "google_compute_route" "default_route" {
  name             = "${var.prefix}-default-route"
  project          = var.project_id
  network          = google_compute_network.vpc.name
  dest_range       = "0.0.0.0/0"
  priority         = 1000
  next_hop_gateway = "default-internet-gateway"

  depends_on = [google_compute_network.vpc]

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.prefix}-subnet"
  project       = var.project_id
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr
  region        = var.region

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

resource "google_compute_global_address" "private_ip_address" {
  provider      = google
  project       = var.project_id
  name          = "${var.prefix}-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_service_networking_connection" "private_vpc_connection" {
  provider                = google
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]

  lifecycle {
    create_before_destroy = true
  }

  deletion_policy = "ABANDON"
}

# =============================================================================
# INLINE: GKE Cluster & Service Accounts
# =============================================================================
# Preserves the exact old GKE module resources.
# The new GKE module adds private_cluster_config, master_authorized_networks,
# disable_l4_lb_firewall_reconciliation, and enable_l4_ilb_subsetting which
# could trigger cluster updates or recreation.
# =============================================================================

resource "google_service_account" "gke_sa" {
  project      = var.project_id
  account_id   = "${var.prefix}-gke-sa"
  display_name = "GKE Service Account for Materialize"
}

resource "google_service_account" "workload_identity_sa" {
  project      = var.project_id
  account_id   = "${var.prefix}-materialize-sa"
  display_name = "Materialize Workload Identity Service Account"
}

resource "google_container_cluster" "primary" {
  provider = google

  deletion_protection = false

  depends_on = [
    google_service_account.gke_sa,
    google_service_account.workload_identity_sa,
  ]

  name     = "${var.prefix}-gke"
  location = var.region
  project  = var.project_id

  # Matches old module: VPC_NATIVE, no private_cluster_config
  networking_mode = "VPC_NATIVE"
  network         = google_compute_network.vpc.name
  subnetwork      = google_compute_subnetwork.subnet.name

  remove_default_node_pool = true
  initial_node_count       = 1

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }
}

# System node pool — from old GKE module's google_container_node_pool.primary_nodes
resource "google_container_node_pool" "system" {
  provider = google

  name     = "${var.prefix}-system-node-pool"
  location = var.region
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  node_count = var.system_node_pool_node_count

  autoscaling {
    min_node_count = var.system_node_pool_min_nodes
    max_node_count = var.system_node_pool_max_nodes
  }

  node_config {
    machine_type = var.system_node_pool_machine_type
    disk_size_gb = var.system_node_pool_disk_size_gb

    labels = local.system_node_labels

    service_account = google_service_account.gke_sa.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    create_before_destroy = true
    prevent_destroy       = false
  }
}

resource "google_service_account_iam_binding" "workload_identity" {
  depends_on = [
    google_service_account.workload_identity_sa,
    google_container_cluster.primary
  ]
  service_account_id = google_service_account.workload_identity_sa.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/orchestratord]"
  ]
}

# =============================================================================
# INLINE: Database (Cloud SQL)
# =============================================================================
# Preserves the exact old database module resources.
# The new database module uses terraform-google-modules/sql-db/google which
# has completely different internal state paths.
# =============================================================================

resource "time_sleep" "wait_for_vpc" {
  depends_on = [google_service_networking_connection.private_vpc_connection]

  create_duration = var.database_vpc_wait_duration
}

resource "google_sql_database_instance" "materialize" {
  depends_on = [time_sleep.wait_for_vpc]

  name             = "${var.prefix}-pg"
  database_version = var.database_version
  region           = var.region
  project          = var.project_id

  timeouts {
    create = "75m"
    update = "45m"
    delete = "45m"
  }

  settings {
    tier = var.database_tier

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      backup_retention_settings {
        retained_backups = 7
      }
    }

    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }

    user_labels = local.common_labels
  }

  deletion_protection = false
}

resource "google_sql_database" "materialize" {
  name     = var.database_name
  instance = google_sql_database_instance.materialize.name
  project  = var.project_id

  deletion_policy = "ABANDON"
}

resource "google_sql_user" "materialize" {
  name     = var.database_username
  instance = google_sql_database_instance.materialize.name
  password = var.database_password
  project  = var.project_id

  deletion_policy = "ABANDON"
}

# =============================================================================
# MODULE: Materialize Node Pool
# =============================================================================
# The nodepool module's google_container_node_pool resource has the same
# structure as the old module. The kubernetes resources (disk setup daemonset)
# will be recreated with shorter names but that's non-disruptive.
# =============================================================================

module "materialize_nodepool" {
  source     = "../../modules/nodepool"
  depends_on = [google_container_cluster.primary]

  prefix                = "${var.prefix}-mz-swap"
  region                = var.region
  enable_private_nodes  = true
  cluster_name          = google_container_cluster.primary.name
  project_id            = var.project_id
  min_nodes             = var.materialize_node_pool_min_nodes
  max_nodes             = var.materialize_node_pool_max_nodes
  machine_type          = var.materialize_node_pool_machine_type
  disk_size_gb          = var.materialize_node_pool_disk_size_gb
  service_account_email = google_service_account.gke_sa.email
  labels                = local.common_labels

  swap_enabled    = true
  local_ssd_count = var.materialize_node_pool_local_ssd_count

  # Pin to old version to avoid unintended daemonset image upgrade
  disk_setup_image = "materialize/ephemeral-storage-setup-image:v0.4.0"

  # MIGRATION: The old module used "${prefix}-disk-setup" for disk setup
  # resource names. The new module defaults to "disk-setup". We must pass
  # the old name to avoid replacement of 5 Kubernetes resources.
  disk_setup_name = "${var.prefix}-mz-swap-disk-setup"
}

# =============================================================================
# MODULE: Storage (GCS)
# =============================================================================
# Old and new storage modules are identical — same resources, same paths.
# =============================================================================

module "storage" {
  source = "../../modules/storage"

  project_id      = var.project_id
  region          = var.region
  prefix          = var.prefix
  service_account = google_service_account.workload_identity_sa.email
  versioning      = var.storage_bucket_versioning
  version_ttl     = var.storage_bucket_version_ttl

  labels = local.common_labels
}

# =============================================================================
# MODULE: cert-manager
# =============================================================================
# Split from old certificates module.
# Namespace and helm release are state-moved from module.certificates.
# =============================================================================

module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  chart_version = var.cert_manager_chart_version

  depends_on = [
    google_container_cluster.primary,
  ]
}

# =============================================================================
# MODULE: Self-Signed Cluster Issuer
# =============================================================================
# Split from old certificates module.
# Uses kubectl_manifest (old used kubernetes_manifest), so these resources
# are skipped during state migration and recreated fresh.
# kubectl_manifest will adopt the existing Kubernetes CRDs.
# =============================================================================

module "self_signed_cluster_issuer" {
  count = var.use_self_signed_cluster_issuer ? 1 : 0

  source = "../../../kubernetes/modules/self-signed-cluster-issuer"

  name_prefix = var.prefix

  depends_on = [
    module.cert_manager,
  ]
}

# =============================================================================
# MODULE: Materialize Operator
# =============================================================================
# Old used external GitHub module with count (module.operator[0]).
# New uses local module without count (module.operator).
# State paths are adjusted by the migration script.
# =============================================================================

module "operator" {
  source = "../../modules/operator"

  # MIGRATION: The old module named the helm release "${namespace}-${environment}"
  # which defaults to "materialize-${prefix}". The new module uses name_prefix
  # directly as the helm release name. We must pass the old combined name to
  # avoid a helm release REPLACEMENT (destroy + recreate).
  name_prefix = "materialize-${var.prefix}"
  region      = var.region

  operator_version = var.operator_version

  # MIGRATION: The old module hardcoded environmentd.nodeSelector to schedule
  # environmentd pods on swap-enabled nodes. The new module defaults to {}.
  # We must preserve the old value to avoid rescheduling pods.
  helm_values = merge(
    {
      environmentd = {
        nodeSelector = {
          "materialize.cloud/swap" = "true"
        }
      }
    },
    var.use_self_signed_cluster_issuer ? {
      tls = {
        defaultCertificateSpecs = {
          balancerdExternal = {
            dnsNames = [
              "balancerd",
            ]
            issuerRef = {
              name = "${var.prefix}-root-ca"
              kind = "ClusterIssuer"
            }
          }
          consoleExternal = {
            dnsNames = [
              "console",
            ]
            issuerRef = {
              name = "${var.prefix}-root-ca"
              kind = "ClusterIssuer"
            }
          }
          internal = {
            issuerRef = {
              name = "${var.prefix}-root-ca"
              kind = "ClusterIssuer"
            }
          }
        }
      }
    } : {}
  )

  depends_on = [
    google_container_cluster.primary,
    module.materialize_nodepool,
    google_sql_database_instance.materialize,
    module.storage,
    module.cert_manager,
  ]
}

# =============================================================================
# MODULE: Materialize Instance
# =============================================================================
# Instance resources are moved from the old external operator module to this
# dedicated instance module. kubernetes_manifest → kubectl_manifest type
# change means the instance CRD is recreated (kubectl_manifest adopts the
# existing K8s resource without disruption).
# =============================================================================

module "materialize_instance" {
  source = "../../../kubernetes/modules/materialize-instance"

  instance_name      = var.materialize_instance_name
  instance_namespace = var.materialize_instance_namespace

  metadata_backend_url = local.metadata_backend_url
  persist_backend_url  = local.persist_backend_url

  license_key        = var.license_key
  authenticator_kind = var.authenticator_kind

  external_login_password_mz_system = var.external_login_password_mz_system

  environmentd_version = var.environmentd_version

  service_account_annotations = {
    "iam.gke.io/gcp-service-account" = google_service_account.workload_identity_sa.email
  }

  issuer_ref = var.use_self_signed_cluster_issuer ? {
    name = "${var.prefix}-root-ca"
    kind = "ClusterIssuer"
  } : null

  depends_on = [
    google_container_cluster.primary,
    google_sql_database_instance.materialize,
    module.storage,
    module.self_signed_cluster_issuer,
    module.operator,
    module.materialize_nodepool,
  ]
}

# =============================================================================
# MODULE: Load Balancers
# =============================================================================
# Old used for_each on instances. New uses direct single-instance call.
# State paths adjusted by migration script.
# New module also creates firewall rules (not in old module — will be added).
# =============================================================================

module "load_balancers" {
  source = "../../modules/load_balancers"

  project_id                 = var.project_id
  network_name               = google_compute_network.vpc.name
  prefix                     = var.prefix
  node_service_account_email = google_service_account.gke_sa.email
  internal                   = var.internal_load_balancer
  ingress_cidr_blocks        = var.ingress_cidr_blocks
  instance_name              = var.materialize_instance_name
  namespace                  = var.materialize_instance_namespace
  resource_id                = module.materialize_instance.instance_resource_id

  depends_on = [
    module.materialize_instance,
  ]
}

# =============================================================================
# CoreDNS — COMMENTED OUT
# =============================================================================
# CoreDNS is a new feature that replaces GKE's kube-dns with zero-TTL caching.
# It is NOT part of the old setup. Uncomment after migration if desired.
#
# module "coredns" {
#   source                                      = "../../../kubernetes/modules/coredns"
#   create_coredns_service_account              = true
#   kubeconfig_data                             = local.kubeconfig_data
#   coredns_deployment_to_scale_down            = "kube-dns"
#   coredns_autoscaler_deployment_to_scale_down = "kube-dns-autoscaler"
#   depends_on = [
#     google_container_cluster.primary,
#   ]
# }
# =============================================================================

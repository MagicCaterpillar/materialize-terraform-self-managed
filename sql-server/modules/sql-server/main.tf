locals {
  labels = {
    "app.kubernetes.io/name"       = "mssql"
    "app.kubernetes.io/instance"   = var.name_prefix
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# ---------------------------------------------------------------------------
# SA Password
# ---------------------------------------------------------------------------

resource "random_password" "sa_password" {
  count = var.sa_password == null ? 1 : 0

  length           = 24
  special          = true
  override_special = "!@#$%^&*()_+-="
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

locals {
  effective_sa_password = var.sa_password != null ? var.sa_password : random_password.sa_password[0].result
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "sql_server" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

# ---------------------------------------------------------------------------
# Secret – SA password stored in-cluster, referenced by the container env
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "sa_password" {
  metadata {
    name      = "${var.name_prefix}-sa-password"
    namespace = kubernetes_namespace.sql_server.metadata[0].name
    labels    = local.labels
  }

  data = {
    MSSQL_SA_PASSWORD = local.effective_sa_password
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# Persistent Volume Claim
#
# Data, log and backup files are stored on an Azure Disk that is mounted at
# /var/opt/mssql inside the container.  The disk is independent of the pod
# lifecycle: destroying or restarting the pod leaves the disk intact, and a
# new pod will reattach it automatically.
#
# NOTE: ReadWriteOnce means only one pod may mount the disk at a time, which
# is why the Deployment uses strategy.type = "Recreate" (the old pod must
# terminate fully before the new one starts).
#
# To resize the PVC: update data_storage_size and run terraform apply.
# Azure Disk storage classes support online volume expansion without downtime.
#
# WARNING: running `terraform destroy` will delete this PVC and its backing
# Azure Disk.  Take a backup before destroying the deployment.
# ---------------------------------------------------------------------------

resource "kubernetes_persistent_volume_claim" "sql_data" {
  metadata {
    name      = "${var.name_prefix}-data"
    namespace = kubernetes_namespace.sql_server.metadata[0].name
    labels    = local.labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class_name

    resources {
      requests = {
        storage = var.data_storage_size
      }
    }
  }

  # Do not wait for immediate bind here. AKS disk storage classes commonly use
  # WaitForFirstConsumer, so binding happens only after a pod is created.
  # Waiting here would deadlock Terraform before the Deployment is created.
  wait_until_bound = false
}

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "sql_server" {
  metadata {
    name      = var.name_prefix
    namespace = kubernetes_namespace.sql_server.metadata[0].name
    labels    = local.labels
  }

  spec {
    # SQL Server standalone does not support multi-replica without Availability
    # Groups.  Always 1.
    replicas = 1

    selector {
      match_labels = local.labels
    }

    # Recreate is required for ReadWriteOnce PVCs: the existing pod must fully
    # terminate before the new one can mount the same disk.
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Give SQL Server time to flush in-flight transactions on shutdown.
        termination_grace_period_seconds = 60

        # Ensure the PVC is writable by the mssql user (UID/GID 10001) that
        # the container image runs as.
        security_context {
          fs_group = 10001
        }

        node_selector = var.node_selector

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        container {
          name  = "mssql"
          image = "mcr.microsoft.com/mssql/server:${var.image_tag}"

          port {
            name           = "mssql"
            container_port = 1433
            protocol       = "TCP"
          }

          # ---- SQL Server environment variables ----------------------------

          env {
            name  = "ACCEPT_EULA"
            value = "Y"
          }

          env {
            name  = "MSSQL_PID"
            value = var.sql_server_pid
          }

          # SQL Server Agent is required for CDC replication jobs.
          env {
            name  = "MSSQL_AGENT_ENABLED"
            value = var.enable_sql_agent ? "true" : "false"
          }

          # SA password sourced from the Kubernetes secret (not baked into the
          # pod spec as a plain-text value).
          env {
            name = "MSSQL_SA_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.sa_password.metadata[0].name
                key  = "MSSQL_SA_PASSWORD"
              }
            }
          }

          # Optional explicit memory cap.  When null, SQL Server 2022 reads
          # the container cgroup limit and configures itself automatically.
          dynamic "env" {
            for_each = var.max_server_memory_mb != null ? [var.max_server_memory_mb] : []
            content {
              name  = "MSSQL_MEMORY_LIMIT_MB"
              value = tostring(env.value)
            }
          }

          # ---- Resource requests / limits ---------------------------------
          # Requests: guaranteed allocation – used for scheduling decisions.
          # Limits:   hard ceiling  – adjust upward for load tests.

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          # ---- Persistent storage -----------------------------------------
          # Mount the Azure Disk PVC at the SQL Server data directory.
          # All database files, logs and system databases reside here.

          volume_mount {
            name       = "sql-data"
            mount_path = "/var/opt/mssql"
          }

          # ---- Health probes ----------------------------------------------

          # Liveness: restart the container if TCP port 1433 stops accepting
          # connections (e.g. SQL Server process crash).
          liveness_probe {
            tcp_socket {
              port = 1433
            }
            initial_delay_seconds = 30
            period_seconds        = 15
            failure_threshold     = 5
            timeout_seconds       = 5
          }

          # Readiness: only route traffic to the pod once SQL Server is
          # accepting SQL queries (engine fully started, not just TCP open).
          # Uses sqlcmd from the 2022 toolset; -No disables TLS cert
          # validation for the localhost self-signed certificate.
          readiness_probe {
            exec {
              command = [
                "/bin/bash", "-c",
                "/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P \"$MSSQL_SA_PASSWORD\" -No -Q 'SELECT 1' > /dev/null 2>&1"
              ]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 5
            timeout_seconds       = 5
          }
        }

        volume {
          name = "sql-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.sql_data.metadata[0].name
          }
        }
      }
    }
  }

}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

resource "kubernetes_service" "sql_server" {
  metadata {
    name        = var.name_prefix
    namespace   = kubernetes_namespace.sql_server.metadata[0].name
    labels      = local.labels
    annotations = var.service_annotations
  }

  spec {
    selector = local.labels
    type     = var.service_type

    port {
      name        = "mssql"
      port        = 1433
      target_port = 1433
      protocol    = "TCP"
    }
  }
}

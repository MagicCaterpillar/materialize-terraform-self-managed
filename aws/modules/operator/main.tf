resource "kubernetes_namespace" "materialize" {
  metadata {
    name = var.operator_namespace
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.monitoring_namespace
  }
}

locals {
  default_helm_values = {
    observability = {
      podMetrics = {
        enabled = true
      }
    }
    networkPolicies = {
      enabled = var.enable_network_policies
      internal = {
        enabled = var.enable_network_policies
      }
      ingress = {
        enabled = var.enable_network_policies
        cidrs   = ["0.0.0.0/0"]
      }
      egress = {
        enabled = var.enable_network_policies
        cidrs   = ["0.0.0.0/0"]
      }
    }
    operator = {
      args = {
        enableLicenseKeyChecks = var.enable_license_key_checks
      }
      image = var.orchestratord_version == null ? {} : {
        tag = var.orchestratord_version
      },
      cloudProvider = {
        type   = "aws"
        region = var.aws_region
        providers = {
          aws = {
            enabled   = true
            accountID = var.aws_account_id
          }
        }
      }
      clusters = {
        swap_enabled = var.swap_enabled
      }
      # Node selector and tolerations for operator pods
      nodeSelector = var.operator_node_selector
      tolerations  = var.tolerations
    }

    # Materialize workload configurations
    environmentd = {
      nodeSelector = var.instance_node_selector
      tolerations  = var.instance_pod_tolerations
    }
    clusterd = {
      nodeSelector = var.instance_node_selector
      tolerations  = var.instance_pod_tolerations
    }
    balancerd = {
      nodeSelector = var.instance_node_selector
      tolerations  = var.instance_pod_tolerations
    }
    console = {
      nodeSelector = var.instance_node_selector
      tolerations  = var.instance_pod_tolerations
    }
  }
}

resource "helm_release" "materialize_operator" {
  name      = var.name_prefix
  namespace = kubernetes_namespace.materialize.metadata[0].name

  repository = var.use_local_chart ? null : var.helm_repository
  chart      = var.helm_chart
  version    = var.use_local_chart ? null : var.operator_version

  values = [
    yamlencode(provider::deepmerge::mergo(local.default_helm_values, var.helm_values))
  ]

  depends_on = [kubernetes_namespace.materialize]
}

# Allow egress to kube-system (DNS, metrics-server, etc.)
resource "kubernetes_network_policy_v1" "allow_kube_system_egress" {
  count = var.enable_network_policies ? 1 : 0

  metadata {
    name      = "allow-kube-system-egress"
    namespace = kubernetes_namespace.materialize.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }
    }
  }
}

# Allow egress to Kubernetes API server (required for CRD registration)
# The API server in EKS is a managed service outside the cluster, so we need
# to allow HTTPS egress to the control plane IP. Using 0.0.0.0/0 on port 443
# allows the operator to reach the API server regardless of its IP since API 
# Server IP might change dynamically, hence 0.0.0.0/0 is used
resource "kubernetes_network_policy_v1" "allow_api_server_egress" {
  count = var.enable_network_policies ? 1 : 0

  metadata {
    name      = "allow-api-server-egress"
    namespace = kubernetes_namespace.materialize.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }
      ports {
        protocol = "TCP"
        port     = 443
      }
    }
  }
}

# Allow egress from the operator to environmentd on the HTTPS port (6876).
# Recent operator versions call https://<svc>:6876/api/login during generation
# rollout to finalize the Materialize CR. Without this rule the operator wedges
# at status=Applying because the existing policies only permit port 443 egress.
# Scoped to the environmentd pods (by label) in any namespace, because a single
# operator can manage instances across multiple namespaces.
resource "kubernetes_network_policy_v1" "allow_environmentd_egress" {
  count = var.enable_network_policies ? 1 : 0

  metadata {
    name      = "allow-environmentd-egress"
    namespace = kubernetes_namespace.materialize.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "materialize-operator"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {}
        pod_selector {
          match_labels = {
            "materialize.cloud/app" = "environmentd"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = 6876
      }
    }
  }
}

# Allow ingress from Kubernetes API server (required for CRD conversion)
resource "kubernetes_network_policy_v1" "allow_api_server_ingress_to_conversion_webhook" {
  count = var.enable_network_policies ? 1 : 0

  metadata {
    name      = "allow-api-server-ingress-to-conversion-webhook"
    namespace = kubernetes_namespace.materialize.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "materialize-operator"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        protocol = "TCP"
        port     = 8001
      }
    }
  }
}

# Allow ingress from monitoring namespace (Prometheus scraping)
resource "kubernetes_network_policy_v1" "allow_monitoring_ingress" {
  count = var.enable_network_policies ? 1 : 0

  metadata {
    name      = "allow-monitoring-ingress"
    namespace = kubernetes_namespace.materialize.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.monitoring_namespace
          }
        }
      }
    }
  }
}

# Install the metrics-server for monitoring
# Required for the Materialize Console to display cluster metrics
resource "helm_release" "metrics_server" {
  count = var.install_metrics_server ? 1 : 0

  name       = "${var.name_prefix}-metrics-server"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_version

  # Configuration values based on metrics_server_values
  dynamic "set" {
    for_each = var.metrics_server_values.skip_tls_verification ? [1] : []
    content {
      name  = "args[0]"
      value = "--kubelet-insecure-tls"
    }
  }

  set {
    name  = "metrics.enabled"
    value = var.metrics_server_values.metrics_enabled
  }

  # Add node selectors for metrics-server pods if provided
  dynamic "set" {
    for_each = var.operator_node_selector
    content {
      name  = "nodeSelector.${set.key}"
      value = set.value
    }
  }

  # Add tolerations for metrics-server pods if provided
  dynamic "set" {
    for_each = length(var.tolerations) > 0 ? range(length(var.tolerations)) : []
    content {
      name  = "tolerations[${set.value}].key"
      value = var.tolerations[set.value].key
    }
  }

  dynamic "set" {
    for_each = length(var.tolerations) > 0 ? range(length(var.tolerations)) : []
    content {
      name  = "tolerations[${set.value}].operator"
      value = var.tolerations[set.value].operator
    }
  }

  dynamic "set" {
    for_each = length(var.tolerations) > 0 ? [
      for i, toleration in var.tolerations : i
      if toleration.value != null
    ] : []
    content {
      name  = "tolerations[${set.value}].value"
      value = var.tolerations[set.value].value
    }
  }

  dynamic "set" {
    for_each = length(var.tolerations) > 0 ? range(length(var.tolerations)) : []
    content {
      name  = "tolerations[${set.value}].effect"
      value = var.tolerations[set.value].effect
    }
  }

  depends_on = [
    kubernetes_namespace.monitoring
  ]
}

locals {
  service_account_name = "aws-node"
  namespace            = "kube-system"
}

# Annotate existing VPC CNI resources for Helm adoption
# EKS creates these resources by default, and Helm needs ownership annotations to manage them
resource "terraform_data" "annotate_existing_resources" {
  count = var.adopt_existing_resources ? 1 : 0

  input = {
    ROLE_ARN        = aws_iam_role.vpc_cni.arn
    KUBECONFIG_DATA = var.kubeconfig_data
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    environment = self.input
    command     = <<-EOF
      set -euo pipefail

      kubeconfig_file=$(mktemp)
      trap "rm -f '$${kubeconfig_file}'" EXIT
      echo "$${KUBECONFIG_DATA}" > "$${kubeconfig_file}"

      helm_annotate() {
        kubectl --kubeconfig "$${kubeconfig_file}" annotate "$@" meta.helm.sh/release-name=aws-vpc-cni meta.helm.sh/release-namespace=kube-system --overwrite
        kubectl --kubeconfig "$${kubeconfig_file}" label "$@" app.kubernetes.io/managed-by=Helm --overwrite
      }

      # Namespaced resources
      helm_annotate daemonset aws-node -n kube-system
      helm_annotate serviceaccount aws-node -n kube-system
      helm_annotate configmap amazon-vpc-cni -n kube-system

      # Cluster-scoped resources
      helm_annotate clusterrole aws-node
      helm_annotate clusterrolebinding aws-node

      # Add IRSA annotation to service account
      kubectl --kubeconfig "$${kubeconfig_file}" annotate serviceaccount aws-node -n kube-system \
        eks.amazonaws.com/role-arn="$${ROLE_ARN}" --overwrite

      echo "VPC CNI resources annotated for Helm adoption."
    EOF
  }
}

# IAM role for VPC CNI with OIDC trust
resource "aws_iam_role" "vpc_cni" {
  name                 = "${var.name_prefix}-vpc-cni"
  permissions_boundary = var.iam_permissions_boundary
  tags                 = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${trimprefix(var.oidc_issuer_url, "https://")}:sub" = "system:serviceaccount:${local.namespace}:${local.service_account_name}"
            "${trimprefix(var.oidc_issuer_url, "https://")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Attach AWS managed policy for VPC CNI
resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Helm release for VPC CNI
resource "helm_release" "vpc_cni" {
  name       = "aws-vpc-cni"
  chart      = "aws-vpc-cni"
  repository = "https://aws.github.io/eks-charts"
  version    = var.chart_version
  namespace  = local.namespace

  # Use existing service account (annotated by terraform_data.annotate_existing_resources)
  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = local.service_account_name
  }

  # Network Policy configuration
  set {
    name  = "enableNetworkPolicy"
    value = tostring(var.enable_network_policy)
  }

  dynamic "set" {
    for_each = var.enable_network_policy ? [1] : []
    content {
      name  = "nodeAgent.enablePolicyEventLogs"
      value = tostring(var.enable_policy_event_logs)
    }
  }

  # https://github.com/aws/amazon-vpc-cni-k8s#cni-configuration-variables
  # Prefix delegation settings
  dynamic "set" {
    for_each = var.enable_prefix_delegation ? [1] : []
    content {
      name  = "env.ENABLE_PREFIX_DELEGATION"
      value = "true"
    }
  }

  dynamic "set" {
    for_each = var.enable_prefix_delegation ? [1] : []
    content {
      name  = "env.WARM_PREFIX_TARGET"
      value = tostring(var.warm_prefix_target)
    }
  }

  # IP management settings
  dynamic "set" {
    for_each = var.minimum_ip_target != null ? [1] : []
    content {
      name  = "env.MINIMUM_IP_TARGET"
      value = tostring(var.minimum_ip_target)
    }
  }

  dynamic "set" {
    for_each = var.warm_ip_target != null ? [1] : []
    content {
      name  = "env.WARM_IP_TARGET"
      value = tostring(var.warm_ip_target)
    }
  }

  set {
    name  = "originalMatchLabels"
    value = "true"
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni,
    terraform_data.annotate_existing_resources
  ]
}

locals {
  namespace            = "karpenter"
  service_account_name = "karpenter"
  oidc_issuer_url      = trimprefix(var.cluster_oidc_issuer_url, "https://")
}

####################################################
# EC2 instance interruption notification SQS Queue
####################################################
resource "aws_sqs_queue" "interruption" {
  name                      = "${var.name_prefix}-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id
  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Sid" : "EC2InterruptionPolicy",
          "Principal" : {
            "Service" : [
              "events.amazonaws.com",
              "sqs.amazonaws.com",
            ],
          },
          "Effect" : "Allow",
          "Action" : "sqs:SendMessage",
          "Resource" : aws_sqs_queue.interruption.arn,
        },
        {
          "Sid" : "DenyHTTP",
          "Principal" : "*",
          "Effect" : "Deny",
          "Action" : "sqs:*",
          "Resource" : aws_sqs_queue.interruption.arn,
          "Condition" : {
            "Bool" : {
              "aws:SecureTransport" : "false",
            },
          },
        },
      ],
    },
  )
}

resource "aws_cloudwatch_event_rule" "scheduled_interruption" {
  name        = "${var.name_prefix}-scheduled-interruption"
  description = "Scheduled changes to EC2 instances"

  event_pattern = jsonencode(
    {
      "source" : ["aws.health"],
      "detail-type" : ["AWS Health Event"],
    },
  )

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "scheduled_interruption" {
  rule = aws_cloudwatch_event_rule.scheduled_interruption.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.name_prefix}-spot-interruption"
  description = "Scheduled changes to EC2 instances"

  event_pattern = jsonencode(
    {
      "source" : ["aws.ec2"],
      "detail-type" : ["EC2 Spot Instance Interruption Warning"],
    },
  )

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_rule" "rebalance_interruption" {
  name        = "${var.name_prefix}-rebalance-interruption"
  description = "Scheduled changes to EC2 instances"

  event_pattern = jsonencode(
    {
      "source" : ["aws.ec2"],
      "detail-type" : ["EC2 Instance Rebalance Recommendation"],
    },
  )

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "rebalance_interruption" {
  rule = aws_cloudwatch_event_rule.rebalance_interruption.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_rule" "state_change_interruption" {
  name        = "${var.name_prefix}-state-change-interruption"
  description = "Scheduled changes to EC2 instances"

  event_pattern = jsonencode(
    {
      "source" : ["aws.ec2"],
      "detail-type" : ["EC2 Instance State-change Notification"],
    },
  )

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "state_change_interruption" {
  rule = aws_cloudwatch_event_rule.state_change_interruption.name
  arn  = aws_sqs_queue.interruption.arn
}

####################################################
# Node IAM
####################################################
resource "aws_iam_role" "node" {
  name                 = "${var.name_prefix}-node"
  permissions_boundary = var.iam_permissions_boundary

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.name_prefix}-karpenter-node"
  role = aws_iam_role.node.name

  tags = var.tags
}

# TODO use a separate IAM role attached to the aws-node service account
resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"

  tags = var.tags
}

####################################################
# Karpenter Controller IAM
####################################################
resource "aws_iam_policy" "karpenter_controller" {
  name = "${var.name_prefix}-karpenter-controller"
  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Resource" : "*",
          "Action" : [
            # Write Operations
            "ec2:CreateLaunchTemplate",
            "ec2:CreateFleet",
            "ec2:RunInstances",
            "ec2:CreateTags",
            "ec2:DeleteLaunchTemplate",
            # Read Operations
            "ec2:DescribeLaunchTemplates",
            "ec2:DescribeInstances",
            "ec2:DescribeSecurityGroups",
            "ec2:DescribeSubnets",
            "ec2:DescribeImages",
            "ec2:DescribeInstanceTypes",
            "ec2:DescribeInstanceTypeOfferings",
            "ec2:DescribeAvailabilityZones",
            "ec2:DescribeSpotPriceHistory",
            "ssm:GetParameter",
            "pricing:GetProducts",
            "iam:GetInstanceProfile",
            "iam:ListInstanceProfiles",
          ],
        },
        {
          "Sid" : "AllowInterruptionQueueActions",
          "Effect" : "Allow",
          "Resource" : aws_sqs_queue.interruption.arn,
          "Action" : [
            "sqs:DeleteMessage",
            "sqs:GetQueueUrl",
            "sqs:ReceiveMessage",
          ],
        },
        {
          "Effect" : "Allow",
          "Resource" : "*",
          "Action" : [
            "ec2:TerminateInstances",
          ],
          "Condition" : {
            "StringLike" : {
              "ec2:ResourceTag/karpenter.sh/managed-by" : var.cluster_name,
            },
          },
        },
        {
          "Effect" : "Allow",
          "Resource" : "*",
          "Action" : [
            "ec2:TerminateInstances",
          ],
          "Condition" : {
            "StringLike" : {
              "ec2:ResourceTag/eks:eks-cluster-name" : var.cluster_name,
            },
          },
        },
        {
          "Effect" : "Allow",
          "Action" : "iam:PassRole",
          "Resource" : aws_iam_role.node.arn,
        },
      ],
    },
  )

  tags = var.tags
}

resource "aws_iam_role" "karpenter_controller" {
  name                 = "${var.name_prefix}-karpenter-controller"
  permissions_boundary = var.iam_permissions_boundary
  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Principal" : {
            "Federated" : var.oidc_provider_arn,
          },
          "Action" : "sts:AssumeRoleWithWebIdentity",
          "Condition" : {
            "StringEquals" : {
              "${local.oidc_issuer_url}:sub" : "system:serviceaccount:${local.namespace}:${local.service_account_name}",
            },
          },
        },
      ],
    },
  )

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  policy_arn = aws_iam_policy.karpenter_controller.arn
  role       = aws_iam_role.karpenter_controller.name
}

####################################################
# Kubernetes resources
####################################################
resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = local.namespace
  }
}

resource "kubernetes_service_account" "karpenter_controller" {
  metadata {
    name      = local.service_account_name
    namespace = kubernetes_namespace.karpenter.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" : aws_iam_role.karpenter_controller.arn
    }
  }
}

resource "helm_release" "karpenter" {
  namespace  = kubernetes_namespace.karpenter.metadata[0].name
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.helm_chart_version

  values = [
    jsonencode(
      {
        "nodeSelector" : var.node_selector,
        "controller" : {
          "resources" : {
            "limits" : {
              "memory" : "1Gi",
            },
            "requests" : {
              "cpu" : "200m",
              "memory" : "1Gi",
            },
          },
        },
        "dnsPolicy" : "Default",
        "serviceAccount" : {
          "name" : kubernetes_service_account.karpenter_controller.metadata[0].name,
          "create" : false,
        },
        "settings" : {
          "clusterName" : var.cluster_name,
          "clusterEndpoint" : var.cluster_endpoint,
          "vmMemoryOverheadPercent" : var.vm_memory_overhead_percent,
          "interruptionQueue" : aws_sqs_queue.interruption.name,
        },
      }
    )
  ]
}

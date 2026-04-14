# EBS CSI Driver for EKS
# Required for dynamic provisioning of EBS volumes

# IAM policy for EBS CSI driver
# From: https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json
resource "aws_iam_policy" "ebs_csi_driver" {
  name        = "${var.name_prefix}-ebs-csi-driver"
  description = "EBS CSI Driver policy for EKS"
  tags        = var.tags

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications",
          "ec2:DescribeVolumeStatus"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateSnapshot",
          "ec2:ModifyVolume"
        ],
        "Resource" : "arn:aws:ec2:*:*:volume/*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CopyVolumes"
        ],
        "Resource" : [
          "arn:aws:ec2:*:*:volume/vol-*"
        ]
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:AttachVolume",
          "ec2:DetachVolume"
        ],
        "Resource" : [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:instance/*"
        ]
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateVolume",
          "ec2:EnableFastSnapshotRestores"
        ],
        "Resource" : "arn:aws:ec2:*:*:snapshot/*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateTags"
        ],
        "Resource" : [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:snapshot/*"
        ],
        "Condition" : {
          "StringEquals" : {
            "ec2:CreateAction" : [
              "CreateVolume",
              "CreateSnapshot",
              "CopyVolumes"
            ]
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:DeleteTags"
        ],
        "Resource" : [
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:snapshot/*"
        ]
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateVolume",
          "ec2:CopyVolumes"
        ],
        "Resource" : "arn:aws:ec2:*:*:volume/*",
        "Condition" : {
          "StringLike" : {
            "aws:RequestTag/ebs.csi.aws.com/cluster" : "true"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateVolume",
          "ec2:CopyVolumes"
        ],
        "Resource" : "arn:aws:ec2:*:*:volume/*",
        "Condition" : {
          "StringLike" : {
            "aws:RequestTag/CSIVolumeName" : "*"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:DeleteVolume"
        ],
        "Resource" : "arn:aws:ec2:*:*:volume/*",
        "Condition" : {
          "StringLike" : {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" : "true"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:DeleteVolume"
        ],
        "Resource" : "arn:aws:ec2:*:*:volume/*",
        "Condition" : {
          "StringLike" : {
            "ec2:ResourceTag/CSIVolumeName" : "*"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:DeleteVolume"
        ],
        "Resource" : "arn:aws:ec2:*:*:volume/*",
        "Condition" : {
          "StringLike" : {
            "ec2:ResourceTag/kubernetes.io/created-for/pvc/name" : "*"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateSnapshot"
        ],
        "Resource" : "arn:aws:ec2:*:*:snapshot/*",
        "Condition" : {
          "StringLike" : {
            "aws:RequestTag/CSIVolumeSnapshotName" : "*"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:CreateSnapshot"
        ],
        "Resource" : "arn:aws:ec2:*:*:snapshot/*",
        "Condition" : {
          "StringLike" : {
            "aws:RequestTag/ebs.csi.aws.com/cluster" : "true"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:DeleteSnapshot"
        ],
        "Resource" : "arn:aws:ec2:*:*:snapshot/*",
        "Condition" : {
          "StringLike" : {
            "ec2:ResourceTag/CSIVolumeSnapshotName" : "*"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ec2:DeleteSnapshot"
        ],
        "Resource" : "arn:aws:ec2:*:*:snapshot/*",
        "Condition" : {
          "StringLike" : {
            "ec2:ResourceTag/ebs.csi.aws.com/cluster" : "true"
          }
        }
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "kms:Decrypt",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:CreateGrant"
        ],
        "Resource" : "arn:aws:kms:*:*:key/*"
      }
    ]
  })
}

# IAM role for EBS CSI driver with OIDC trust
resource "aws_iam_role" "ebs_csi_driver" {
  name                 = "${var.name_prefix}-ebs-csi-driver"
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
            "${trimprefix(var.oidc_issuer_url, "https://")}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
            "${trimprefix(var.oidc_issuer_url, "https://")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = aws_iam_policy.ebs_csi_driver.arn
}

# Helm release for EBS CSI driver
resource "helm_release" "ebs_csi_driver" {
  name       = "aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  version    = var.chart_version
  namespace  = var.namespace

  set {
    name  = "controller.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "controller.serviceAccount.name"
    value = var.service_account_name
  }

  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.ebs_csi_driver.arn
  }

  set {
    name  = "controller.serviceAccount.automountServiceAccountToken"
    value = "true"
  }

  # Add node selectors for controller pods if provided
  dynamic "set" {
    for_each = var.node_selector
    content {
      name  = "controller.nodeSelector.${set.key}"
      value = set.value
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_driver
  ]
}

# Create gp3 storage class as default
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = merge(
    {
      type      = "gp3"
      encrypted = "true"
    },
    var.kms_key_id != null ? { kmsKeyId = var.kms_key_id } : {}
  )

  depends_on = [helm_release.ebs_csi_driver]
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_encryption_uses_kms = var.bucket_encryption_mode == "SSE-KMS"
  bucket_sse_algorithm       = local.bucket_encryption_uses_kms ? "aws:kms" : "AES256"
}

resource "aws_s3_bucket" "materialize_storage" {
  bucket        = "${var.name_prefix}-storage-${random_id.bucket_suffix.hex}"
  force_destroy = var.bucket_force_destroy

  tags = var.tags
}

resource "aws_s3_bucket_versioning" "materialize_storage" {
  count = var.enable_bucket_versioning ? 1 : 0 # Only create if versioning is enabled

  bucket = aws_s3_bucket.materialize_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "materialize_storage" {
  count = var.enable_bucket_encryption ? 1 : 0

  bucket = aws_s3_bucket.materialize_storage.id

  lifecycle {
    precondition {
      condition     = !(local.bucket_encryption_uses_kms && var.bucket_kms_key_arn == null)
      error_message = "Set bucket_kms_key_arn when bucket_encryption_mode is SSE-KMS."
    }
  }

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.bucket_sse_algorithm
      kms_master_key_id = local.bucket_encryption_uses_kms ? var.bucket_kms_key_arn : null
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "materialize_storage" {
  count = length(var.bucket_lifecycle_rules) > 0 ? 1 : 0

  bucket = aws_s3_bucket.materialize_storage.id

  dynamic "rule" {
    for_each = var.bucket_lifecycle_rules
    content {
      id     = rule.value.id
      status = rule.value.enabled ? "Enabled" : "Disabled"

      transition {
        days          = rule.value.transition_days
        storage_class = rule.value.transition_storage_class
      }

      noncurrent_version_expiration {
        noncurrent_days = rule.value.noncurrent_version_expiration_days
      }
    }
  }
}

# IAM Role for Service Account (IRSA) to access S3 bucket
resource "aws_iam_role" "materialize_s3" {
  name                 = "${var.name_prefix}-mz-role"
  permissions_boundary = var.iam_permissions_boundary

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
          StringLike = {
            "${trimprefix(var.cluster_oidc_issuer_url, "https://")}:sub" : "system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}",
            "${trimprefix(var.cluster_oidc_issuer_url, "https://")}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-mz-role"
    ManagedBy = "terraform"
  })
}

# IAM Policy for S3 access
resource "aws_iam_role_policy" "materialize_s3" {
  name = "${var.name_prefix}-mz-role-policy"
  role = aws_iam_role.materialize_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.materialize_storage.arn,
          "${aws_s3_bucket.materialize_storage.arn}/*"
        ]
      }
    ]
  })
}

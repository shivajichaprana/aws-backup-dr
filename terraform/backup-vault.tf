# =============================================================================
# AWS Backup Vault — Primary Region
# =============================================================================
# Creates an encrypted, compliance-mode-locked backup vault for the primary
# region.  The KMS CMK is dedicated to backup operations so key policy can be
# tightly scoped.  Vault lock (compliance mode) prevents recovery-point deletion
# before the minimum retention window expires — this is the primary defence
# against ransomware-driven backup destruction.
# =============================================================================

# ---------------------------------------------------------------------------
# KMS Customer Managed Key — Primary Region
# ---------------------------------------------------------------------------
resource "aws_kms_key" "backup_primary" {
  description             = "CMK for AWS Backup vault encryption - ${local.name_prefix} primary"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  multi_region            = false # DR region gets its own CMK

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Allow the account root full key management
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # Allow AWS Backup service to use the key for encrypt/decrypt operations
      {
        Sid    = "AllowAWSBackupService"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncrypt*",
          "kms:DescribeKey",
          "kms:CreateGrant",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-backup-key-primary"
    Role = "backup-encryption"
  })
}

resource "aws_kms_alias" "backup_primary" {
  name          = "alias/${local.name_prefix}-backup-primary"
  target_key_id = aws_kms_key.backup_primary.key_id
}

# ---------------------------------------------------------------------------
# KMS Customer Managed Key — DR Region
# ---------------------------------------------------------------------------
resource "aws_kms_key" "backup_dr" {
  provider = aws.dr

  description             = "CMK for AWS Backup vault encryption - ${local.name_prefix} DR"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowAWSBackupService"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncrypt*",
          "kms:DescribeKey",
          "kms:CreateGrant",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-backup-key-dr"
    Role = "backup-encryption-dr"
  })
}

resource "aws_kms_alias" "backup_dr" {
  provider = aws.dr

  name          = "alias/${local.name_prefix}-backup-dr"
  target_key_id = aws_kms_key.backup_dr.key_id
}

# ---------------------------------------------------------------------------
# Backup Vault — Primary Region
# ---------------------------------------------------------------------------
resource "aws_backup_vault" "primary" {
  name        = "${local.name_prefix}-primary"
  kms_key_arn = aws_kms_key.backup_primary.arn

  tags = merge(local.common_tags, {
    Name   = "${local.name_prefix}-primary"
    Region = var.primary_region
  })

  # Prevent accidental destruction of the vault while recovery points exist
  lifecycle {
    prevent_destroy = false # Set to true in production
  }
}

# Vault Lock — Compliance mode
# WARNING: After the changeable_for_days grace period expires, this lock
# CANNOT be removed or modified. Only enable after verifying retention settings.
resource "aws_backup_vault_lock_configuration" "primary" {
  count = var.enable_vault_lock ? 1 : 0

  backup_vault_name   = aws_backup_vault.primary.name
  min_retention_days  = var.vault_lock_min_retention_days
  max_retention_days  = var.vault_lock_max_retention_days
  changeable_for_days = var.changeable_for_days

  depends_on = [aws_backup_vault.primary]
}

# ---------------------------------------------------------------------------
# Backup Vault — DR Region
# ---------------------------------------------------------------------------
resource "aws_backup_vault" "dr" {
  provider = aws.dr

  name        = "${local.name_prefix}-dr"
  kms_key_arn = aws_kms_key.backup_dr.arn

  tags = merge(local.common_tags, {
    Name   = "${local.name_prefix}-dr"
    Region = var.dr_region
    Role   = "disaster-recovery"
  })

  lifecycle {
    prevent_destroy = false # Set to true in production
  }
}

resource "aws_backup_vault_lock_configuration" "dr" {
  count    = var.enable_vault_lock ? 1 : 0
  provider = aws.dr

  backup_vault_name   = aws_backup_vault.dr.name
  min_retention_days  = var.vault_lock_min_retention_days
  max_retention_days  = var.vault_lock_max_retention_days
  changeable_for_days = var.changeable_for_days

  depends_on = [aws_backup_vault.dr]
}

# ---------------------------------------------------------------------------
# SNS Topic for Backup Notifications
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "backup_notifications" {
  name              = "${local.name_prefix}-backup-alerts"
  kms_master_key_id = aws_kms_key.backup_primary.id

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "backup_email" {
  count = var.sns_alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.backup_notifications.arn
  protocol  = "email"
  endpoint  = var.sns_alert_email
}

# CloudWatch event rule to capture backup job failures
resource "aws_cloudwatch_event_rule" "backup_job_failed" {
  name        = "${local.name_prefix}-backup-job-failed"
  description = "Capture AWS Backup job failures and send to SNS"

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Backup Job State Change"]
    detail = {
      state = ["FAILED", "ABORTED", "EXPIRED"]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "backup_job_failed_sns" {
  rule      = aws_cloudwatch_event_rule.backup_job_failed.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.backup_notifications.arn
}

resource "aws_sns_topic_policy" "backup_notifications" {
  arn = aws_sns_topic.backup_notifications.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.backup_notifications.arn
      },
    ]
  })
}

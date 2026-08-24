# =============================================================================
# AWS Backup Plan — Daily backups with cross-region copy and lifecycle rules
# =============================================================================
# Backup plan covers:
#   - Daily backups at 05:00 UTC with 2-hour completion window
#   - Lifecycle: transition to cold storage after 90 days, delete after 365 days
#   - Cross-region copy to DR vault with 90-day retention
#   - Separate rules for critical (1-hour RPO) vs standard (24-hour RPO) tiers
# =============================================================================

# ---------------------------------------------------------------------------
# IAM Role — AWS Backup Service Role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "backup_assume_role" {
  statement {
    sid     = "AllowBackupServiceAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${local.name_prefix}-backup-role"
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-backup-role"
  })
}

# AWS-managed policies required for full backup coverage
resource "aws_iam_role_policy_attachment" "backup_policy" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore_policy" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# Additional inline policy for S3 backup and cross-region copy
resource "aws_iam_role_policy" "backup_s3_and_cross_region" {
  name = "${local.name_prefix}-backup-s3-cross-region"
  role = aws_iam_role.backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 backup permissions
      {
        Sid    = "S3BackupPermissions"
        Effect = "Allow"
        Action = [
          "s3:GetBucketTagging",
          "s3:GetInventoryConfiguration",
          "s3:ListBucketVersions",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation",
          "s3:GetBucketAcl",
          "s3:PutInventoryConfiguration",
          "s3:GetBucketNotification",
          "s3:PutBucketNotification",
          "s3:GetObject",
          "s3:GetObjectAcl",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectTagging",
          "s3:GetObjectVersion",
          "s3:GetObjectVersionTagging",
        ]
        Resource = "*"
      },
      # KMS permissions for cross-region copy
      {
        Sid    = "KMSCrossRegionCopy"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ReEncrypt*",
        ]
        Resource = [
          aws_kms_key.backup_primary.arn,
          aws_kms_key.backup_dr.arn,
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Backup Plan — Standard (24-hour RPO)
# ---------------------------------------------------------------------------
resource "aws_backup_plan" "standard" {
  name = "${local.name_prefix}-standard"

  # Rule 1: Daily backup — main window
  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = var.backup_schedule_cron
    start_window      = 60   # minutes before schedule to start
    completion_window = var.completion_window_minutes

    lifecycle {
      cold_storage_after = var.warm_storage_after_days
      delete_after       = var.delete_after_days
    }

    # Cross-region copy to DR vault
    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        cold_storage_after = 30
        delete_after       = var.dr_delete_after_days
      }
    }

    recovery_point_tags = merge(local.common_tags, {
      BackupTier = "standard"
      BackupPlan = "${local.name_prefix}-standard"
    })
  }

  # Rule 2: Weekly full backup (retained longer, no cold-storage transition)
  rule {
    rule_name         = "weekly-full-backup"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 2 ? * SUN *)"  # 02:00 UTC every Sunday
    start_window      = 60
    completion_window = 240  # Allow 4 hours for weekly full

    lifecycle {
      delete_after = 365  # Keep weekly snapshots for 1 year
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        delete_after = 180  # Keep DR copies of weeklies for 6 months
      }
    }

    recovery_point_tags = merge(local.common_tags, {
      BackupTier     = "standard"
      BackupSchedule = "weekly-full"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-standard"
  })
}

# ---------------------------------------------------------------------------
# Backup Plan — Critical (1-hour RPO for critical workloads)
# ---------------------------------------------------------------------------
resource "aws_backup_plan" "critical" {
  name = "${local.name_prefix}-critical"

  # Rule 1: Hourly backup during business hours (08:00–20:00 UTC)
  rule {
    rule_name         = "hourly-backup-business-hours"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 8-20 * * ? *)"  # Every hour 08-20 UTC
    start_window      = 30
    completion_window = 60

    lifecycle {
      cold_storage_after = var.warm_storage_after_days
      delete_after       = var.delete_after_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        delete_after = 30  # Keep hourly DR copies for 30 days
      }
    }

    recovery_point_tags = merge(local.common_tags, {
      BackupTier     = "critical"
      BackupSchedule = "hourly"
    })
  }

  # Rule 2: Daily backup for critical resources
  rule {
    rule_name         = "daily-backup-critical"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = var.backup_schedule_cron
    start_window      = 60
    completion_window = var.completion_window_minutes

    lifecycle {
      cold_storage_after = var.warm_storage_after_days
      delete_after       = var.delete_after_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        cold_storage_after = 30
        delete_after       = var.dr_delete_after_days
      }
    }

    recovery_point_tags = merge(local.common_tags, {
      BackupTier     = "critical"
      BackupSchedule = "daily"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-critical"
  })
}

# ---------------------------------------------------------------------------
# Global Settings — Enable resource-based backup policies at org level
# ---------------------------------------------------------------------------
resource "aws_backup_global_settings" "this" {
  global_settings = {
    isCrossAccountBackupEnabled = "true"
  }
}

# ---------------------------------------------------------------------------
# Region Settings — Enable S3 and EFS backup features
# ---------------------------------------------------------------------------
resource "aws_backup_region_settings" "primary" {
  resource_type_opt_in_preference = {
    Aurora     = true
    DocumentDB = true
    DynamoDB   = true
    EBS        = true
    EC2        = true
    EFS        = true
    FSx        = true
    Neptune    = true
    RDS        = true
    Redshift   = true
    S3         = true
    SAP HANA on AWS  = false
    Storage Gateway  = false
    Timestream     = false
    VirtualMachine = false
  }

  resource_type_management_preference = {
    DynamoDB = true
    EFS      = true
  }
}

# =============================================================================
# Backup Vault Lock — Compliance-Mode Immutability & Resource-Based Policies
# =============================================================================
# AWS Backup Vault Lock (compliance mode) makes recovery points immutable for
# the configured retention window — even the AWS root account cannot delete
# them once the grace period expires.  This is the recommended control against
# ransomware actors who compromise administrative credentials and attempt to
# destroy backups before encrypting production data.
#
# This file adds THREE complementary layers on top of the basic vault creation
# already in backup-vault.tf:
#
#   Layer 1 — Vault Access Policy (resource-based)
#     • An explicit DENY on destructive vault operations at the vault resource
#       level, orthogonal to IAM identity-based policies and boundaries.
#     • Applies to EVERY principal that accesses the vault (including root),
#       unless explicitly excluded as the break-glass role.
#
#   Layer 2 — Vault Lock Configuration (compliance mode)
#     • Once the changeable_for_days grace period elapses the vault lock
#       becomes permanent and AWS Support cannot override it.
#     • min_retention_days prevents deletion before the minimum window.
#     • max_retention_days caps accidental infinite retention.
#
#   Layer 3 — Security Monitoring
#     • CloudWatch metric filters on CloudTrail logs for destructive vault
#       API calls, with SNS alerts on any match.
#     • Provides near-real-time alerting if the resource policy is
#       circumvented (e.g. via a new AWS-granted exception mechanism).
#
# IMPORTANT: Vault lock (compliance mode) is IRREVERSIBLE after the grace
# period.  Set enable_vault_lock = false until you have validated the
# retention settings in a non-production environment.
# =============================================================================

# ---------------------------------------------------------------------------
# Variables — Vault Lock & Policy Configuration
# ---------------------------------------------------------------------------
variable "vault_lock_grace_period_reminder_days" {
  description = "Number of days before the vault lock grace period expires to send a reminder SNS alert"
  type        = number
  default     = 1

  validation {
    condition     = var.vault_lock_grace_period_reminder_days >= 1
    error_message = "vault_lock_grace_period_reminder_days must be at least 1."
  }
}

variable "cloudtrail_log_group_name" {
  description = "Name of the CloudWatch log group receiving CloudTrail management events (for vault-tamper alarms)"
  type        = string
  default     = ""  # Leave empty to skip CloudTrail-based metric filters
}

# ---------------------------------------------------------------------------
# Layer 1 — Primary Vault Access Policy
# ---------------------------------------------------------------------------
# This resource-based policy is evaluated BEFORE any IAM identity-based policy.
# It explicitly denies DeleteBackupVault, DeleteRecoveryPoint, and
# related operations for all principals except the break-glass role.
# Even if an IAM policy grants these actions, the resource policy deny wins.
resource "aws_backup_vault_policy" "primary" {
  backup_vault_name = aws_backup_vault.primary.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # -----------------------------------------------------------------
      # ALLOW: Backup service operations needed for normal backup/restore
      # -----------------------------------------------------------------
      {
        Sid    = "AllowBackupServiceOperations"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = [
          "backup:CopyIntoBackupVault",
          "backup:GetRecoveryPointRestoreMetadata",
          "backup:DescribeRecoveryPoint",
          "backup:ListRecoveryPointsByBackupVault",
        ]
        Resource = "*"
      },
      # Allow account principals to read vault contents and start restores
      {
        Sid    = "AllowAccountReadAndRestoreAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action = [
          "backup:DescribeBackupVault",
          "backup:GetBackupVaultAccessPolicy",
          "backup:GetBackupVaultNotifications",
          "backup:ListRecoveryPointsByBackupVault",
          "backup:DescribeRecoveryPoint",
          "backup:GetRecoveryPointRestoreMetadata",
          "backup:StartRestoreJob",
          "backup:StartCopyJob",
        ]
        Resource = "*"
      },
      # -----------------------------------------------------------------
      # DENY: Destructive vault operations — resource-policy layer
      # -----------------------------------------------------------------
      # This deny is evaluated for ALL principals EXCEPT the break-glass role.
      # Combined with the IAM boundary in iam-restrictions.tf, there are now
      # two independent deny layers blocking vault/recovery-point deletion.
      {
        Sid    = "DenyDestructiveVaultOperations"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "backup:DeleteBackupVault",
          "backup:DeleteBackupVaultAccessPolicy",
          "backup:DeleteBackupVaultLockConfiguration",
          "backup:DeleteBackupVaultNotifications",
          "backup:DeleteRecoveryPoint",
        ]
        Resource = "*"
        Condition = {
          # Exclude the break-glass role — it retains emergency deletion rights
          ArnNotLike = {
            "aws:PrincipalArn" = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-backup-break-glass"
          }
        }
      },
    ]
  })

  depends_on = [aws_backup_vault.primary]
}

# ---------------------------------------------------------------------------
# Layer 1 — DR Vault Access Policy (same protections, DR region)
# ---------------------------------------------------------------------------
resource "aws_backup_vault_policy" "dr" {
  provider          = aws.dr
  backup_vault_name = aws_backup_vault.dr.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBackupServiceOperations"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = [
          "backup:CopyIntoBackupVault",
          "backup:GetRecoveryPointRestoreMetadata",
          "backup:DescribeRecoveryPoint",
          "backup:ListRecoveryPointsByBackupVault",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowAccountReadAndRestoreAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action = [
          "backup:DescribeBackupVault",
          "backup:GetBackupVaultAccessPolicy",
          "backup:ListRecoveryPointsByBackupVault",
          "backup:DescribeRecoveryPoint",
          "backup:GetRecoveryPointRestoreMetadata",
          "backup:StartRestoreJob",
          "backup:StartCopyJob",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDestructiveVaultOperations"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "backup:DeleteBackupVault",
          "backup:DeleteBackupVaultAccessPolicy",
          "backup:DeleteBackupVaultLockConfiguration",
          "backup:DeleteBackupVaultNotifications",
          "backup:DeleteRecoveryPoint",
        ]
        Resource = "*"
        Condition = {
          ArnNotLike = {
            "aws:PrincipalArn" = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-backup-break-glass"
          }
        }
      },
    ]
  })

  depends_on = [aws_backup_vault.dr]
}

# ---------------------------------------------------------------------------
# Layer 2 — Vault Lock: primary & DR vaults
# NOTE: The aws_backup_vault_lock_configuration resources in backup-vault.tf
# manage the actual lock objects.  The variables controlling lock behaviour
# (enable_vault_lock, vault_lock_min_retention_days, changeable_for_days, etc.)
# are declared in variables.tf and shared between both files.
#
# This section adds supplementary EventBridge rules that fire BEFORE the lock
# grace period expires to remind operators to validate retention settings.
# ---------------------------------------------------------------------------

# EventBridge scheduled rule — fire daily during the vault lock grace period
# to remind operators the lock will become permanent soon.
resource "aws_cloudwatch_event_rule" "vault_lock_grace_reminder" {
  count       = var.enable_vault_lock ? 1 : 0
  name        = "${local.name_prefix}-vault-lock-grace-reminder"
  description = "Daily reminder during vault lock grace period — lock becomes permanent after ${var.changeable_for_days} days"
  # Fire once a day at 09:00 UTC
  schedule_expression = "cron(0 9 * * ? *)"

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-vault-lock-grace-reminder"
    Purpose = "vault-lock-grace-reminder"
  })
}

resource "aws_cloudwatch_event_target" "vault_lock_grace_reminder" {
  count     = var.enable_vault_lock ? 1 : 0
  rule      = aws_cloudwatch_event_rule.vault_lock_grace_reminder[0].name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.backup_notifications.arn

  input = jsonencode({
    source      = "aws-backup-dr-automation"
    detail-type = "VaultLockGraceReminder"
    detail = {
      message            = "Backup vault lock is enabled. Verify retention settings before the ${var.changeable_for_days}-day grace period expires."
      vault_names        = ["${local.name_prefix}-primary", "${local.name_prefix}-dr"]
      min_retention_days = var.vault_lock_min_retention_days
      max_retention_days = var.vault_lock_max_retention_days
      changeable_for     = "${var.changeable_for_days} days"
    }
  })
}

# Allow EventBridge to publish to the SNS topic
resource "aws_sns_topic_policy" "vault_lock_events" {
  count = var.enable_vault_lock ? 1 : 0
  arn   = aws_sns_topic.backup_notifications.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgeVaultLockReminder"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.backup_notifications.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.vault_lock_grace_reminder[0].arn
          }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Layer 3 — CloudTrail-Based Security Monitoring
# Detects attempted vault/recovery-point deletions in near-real-time even if
# they are blocked by policy (API call still appears in CloudTrail).
# ---------------------------------------------------------------------------

# Only create metric filters when a CloudTrail log group is configured
locals {
  cloudtrail_monitoring_enabled = var.cloudtrail_log_group_name != ""
}

# Metric filter: any backup vault deletion API call (blocked or not)
resource "aws_cloudwatch_log_metric_filter" "backup_vault_deletion_attempt" {
  count          = local.cloudtrail_monitoring_enabled ? 1 : 0
  name           = "${local.name_prefix}-vault-deletion-attempt"
  pattern        = "{ ($.eventSource = \"backup.amazonaws.com\") && (($.eventName = \"DeleteBackupVault\") || ($.eventName = \"DeleteBackupVaultLockConfiguration\") || ($.eventName = \"DeleteBackupVaultAccessPolicy\")) }"
  log_group_name = var.cloudtrail_log_group_name

  metric_transformation {
    name      = "BackupVaultDeletionAttempts"
    namespace = "${local.name_prefix}/BackupSecurity"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "backup_vault_deletion_attempt" {
  count               = local.cloudtrail_monitoring_enabled ? 1 : 0
  alarm_name          = "${local.name_prefix}-vault-deletion-attempt"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "BackupVaultDeletionAttempts"
  namespace           = "${local.name_prefix}/BackupSecurity"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "CRITICAL: Backup vault deletion was attempted — investigate immediately for ransomware or insider threat"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.backup_notifications.arn]
  ok_actions    = []

  tags = merge(local.common_tags, {
    Name     = "${local.name_prefix}-vault-deletion-attempt"
    Severity = "critical"
  })
}

# Metric filter: recovery point deletion attempts
resource "aws_cloudwatch_log_metric_filter" "recovery_point_deletion_attempt" {
  count          = local.cloudtrail_monitoring_enabled ? 1 : 0
  name           = "${local.name_prefix}-recovery-point-deletion-attempt"
  pattern        = "{ ($.eventSource = \"backup.amazonaws.com\") && ($.eventName = \"DeleteRecoveryPoint\") }"
  log_group_name = var.cloudtrail_log_group_name

  metric_transformation {
    name      = "RecoveryPointDeletionAttempts"
    namespace = "${local.name_prefix}/BackupSecurity"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "recovery_point_deletion_attempt" {
  count               = local.cloudtrail_monitoring_enabled ? 1 : 0
  alarm_name          = "${local.name_prefix}-recovery-point-deletion-attempt"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RecoveryPointDeletionAttempts"
  namespace           = "${local.name_prefix}/BackupSecurity"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "WARNING: Recovery point deletion was attempted — verify this is authorised and matches break-glass procedure"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.backup_notifications.arn]
  ok_actions    = []

  tags = merge(local.common_tags, {
    Name     = "${local.name_prefix}-recovery-point-deletion-attempt"
    Severity = "warning"
  })
}

# Metric filter: backup job cancellation attempts (ransomware tactic)
resource "aws_cloudwatch_log_metric_filter" "backup_job_stop_attempt" {
  count          = local.cloudtrail_monitoring_enabled ? 1 : 0
  name           = "${local.name_prefix}-backup-job-stop-attempt"
  pattern        = "{ ($.eventSource = \"backup.amazonaws.com\") && ($.eventName = \"StopBackupJob\") }"
  log_group_name = var.cloudtrail_log_group_name

  metric_transformation {
    name      = "BackupJobStopAttempts"
    namespace = "${local.name_prefix}/BackupSecurity"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "backup_job_stop_attempt" {
  count               = local.cloudtrail_monitoring_enabled ? 1 : 0
  alarm_name          = "${local.name_prefix}-backup-job-stop-attempt"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "BackupJobStopAttempts"
  namespace           = "${local.name_prefix}/BackupSecurity"
  period              = 300
  statistic           = "Sum"
  threshold           = 3 # Alert on 3+ cancellations within 5 minutes
  alarm_description   = "WARNING: Multiple backup job cancellations detected within 5 minutes — investigate for ransomware"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.backup_notifications.arn]
  ok_actions    = []

  tags = merge(local.common_tags, {
    Name     = "${local.name_prefix}-backup-job-stop-attempt"
    Severity = "warning"
  })
}

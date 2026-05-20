# =============================================================================
# IAM Restrictions — Prevent Backup Infrastructure Deletion
# =============================================================================
# This file establishes two layers of IAM-level protection for the backup
# infrastructure:
#
#   1. Permission Boundary — An IAM managed policy that, when attached to any
#      IAM principal managing backups, prevents the following destructive
#      operations regardless of the identity-based policies that principal
#      also holds:
#        • backup:DeleteBackupVault
#        • backup:DeleteBackupPlan
#        • backup:DeleteBackupVaultAccessPolicy
#        • backup:DeleteBackupVaultLockConfiguration
#        • backup:DeleteRecoveryPoint
#        • backup:StopBackupJob  (without MFA, outside break-glass role)
#
#   2. Backup Admin Role — A dedicated IAM role scoped to backup management
#      operations, with the permission boundary pre-attached.  Operators
#      assume this role to manage backup plans and monitor jobs without the
#      ability to destroy vault data.
#
#   3. Break-Glass Role — A separate IAM role that retains the ability to
#      perform emergency recovery operations (e.g. cancelling a runaway job).
#      This role is kept dormant and requires MFA within a 15-minute window.
#      It is the ONLY principal excluded from the destructive-operation deny.
#
# NOTE: IAM permission boundaries narrow permissions — they do NOT grant them.
# Principals still need identity-based policies allowing the actions they use.
# =============================================================================

# ---------------------------------------------------------------------------
# Local: Role names used in policy conditions
# ---------------------------------------------------------------------------
locals {
  break_glass_role_name  = "${local.name_prefix}-backup-break-glass"
  backup_admin_role_name = "${local.name_prefix}-backup-admin"
}

# ---------------------------------------------------------------------------
# 1. IAM Managed Policy: Permission Boundary
#    Attach this as PermissionsBoundary on all backup operator roles.
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "backup_admin_boundary" {
  name        = "${local.name_prefix}-backup-admin-boundary"
  description = "Permission boundary for backup administrators: allows full backup management but prevents vault/plan/recovery-point deletion"
  path        = "/backup/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # -----------------------------------------------------------------------
      # ALLOW: Full backup read and operational permissions
      # -----------------------------------------------------------------------
      {
        Sid    = "AllowBackupReadAndOperations"
        Effect = "Allow"
        Action = [
          "backup:Describe*",
          "backup:Get*",
          "backup:List*",
          "backup:CreateBackupVault",
          "backup:CreateBackupPlan",
          "backup:CreateBackupSelection",
          "backup:StartBackupJob",
          "backup:StartRestoreJob",
          "backup:StartCopyJob",
          "backup:TagResource",
          "backup:UntagResource",
          "backup:PutBackupVaultAccessPolicy",
          "backup:PutBackupVaultLockConfiguration",
          "backup:PutBackupVaultNotifications",
          "backup:UpdateBackupPlan",
          "backup:UpdateGlobalSettings",
          "backup:UpdateRegionSettings",
          "backup:UpdateRecoveryPointLifecycle",
        ]
        Resource = "*"
      },
      # Allow read access for backup job monitoring
      {
        Sid    = "AllowReadAccessForBackupMonitoring"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "rds:DescribeDBInstances",
          "rds:DescribeDBClusters",
          "dynamodb:DescribeTable",
          "dynamodb:ListTables",
          "efs:DescribeFileSystems",
          "s3:ListAllMyBuckets",
          "s3:GetBucketLocation",
          "s3:GetBucketTagging",
          "fsx:DescribeFileSystems",
          "tag:GetResources",
          "tag:GetTagKeys",
          "tag:GetTagValues",
        ]
        Resource = "*"
      },
      # KMS read access for key alias resolution
      {
        Sid    = "AllowKMSReadForBackup"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:ListAliases",
          "kms:ListKeys",
        ]
        Resource = "*"
      },
      # CloudWatch / SNS for monitoring backup jobs
      {
        Sid    = "AllowCloudWatchAndSNSForMonitoring"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "sns:ListTopics",
          "sns:GetTopicAttributes",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      },
      # IAM: allow passing the backup service role only
      {
        Sid    = "AllowPassBackupServiceRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-backup-role",
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "backup.amazonaws.com"
          }
        }
      },

      # -----------------------------------------------------------------------
      # DENY: Destructive backup operations — enforced at boundary layer.
      # These Deny statements take precedence over any identity-based Allow.
      # The break-glass role is excluded via ArnNotLike condition.
      # -----------------------------------------------------------------------
      {
        Sid    = "DenyBackupVaultDeletion"
        Effect = "Deny"
        Action = [
          "backup:DeleteBackupVault",
          "backup:DeleteBackupVaultAccessPolicy",
          "backup:DeleteBackupVaultLockConfiguration",
          "backup:DeleteBackupVaultNotifications",
        ]
        Resource = "*"
        Condition = {
          ArnNotLike = {
            "aws:PrincipalArn" = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-backup-break-glass"
          }
        }
      },
      {
        Sid    = "DenyBackupPlanDeletion"
        Effect = "Deny"
        Action = [
          "backup:DeleteBackupPlan",
          "backup:DeleteBackupSelection",
        ]
        Resource = "*"
        Condition = {
          ArnNotLike = {
            "aws:PrincipalArn" = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-backup-break-glass"
          }
        }
      },
      {
        Sid    = "DenyRecoveryPointDeletion"
        Effect = "Deny"
        Action = [
          "backup:DeleteRecoveryPoint",
        ]
        Resource = "*"
        Condition = {
          ArnNotLike = {
            "aws:PrincipalArn" = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-backup-break-glass"
          }
        }
      },
      {
        Sid    = "DenyStopBackupJobWithoutMFA"
        Effect = "Deny"
        Action = [
          "backup:StopBackupJob",
        ]
        Resource = "*"
        Condition = {
          # Require MFA when cancelling active backup jobs —
          # prevents ransomware from interrupting in-flight backups
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
          ArnNotLike = {
            "aws:PrincipalArn" = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-backup-break-glass"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-backup-admin-boundary"
    Purpose = "backup-admin-permission-boundary"
  })
}

# ---------------------------------------------------------------------------
# 2. Backup Admin Role — Day-to-day backup management
#    Operators / automation pipelines assume this role for routine tasks.
#    The permission boundary above is enforced at all times.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "backup_admin_assume_role" {
  statement {
    sid     = "AllowAssumeRoleFromCurrentAccountWithMFA"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    # Require MFA to assume the admin role
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "aws:MultiFactorAuthAge"
      values   = ["3600"] # MFA session < 1 hour old
    }
  }
}

resource "aws_iam_role" "backup_admin" {
  name                 = "${local.name_prefix}-backup-admin"
  assume_role_policy   = data.aws_iam_policy_document.backup_admin_assume_role.json
  permissions_boundary = aws_iam_policy.backup_admin_boundary.arn
  max_session_duration = 3600 # 1 hour — short sessions reduce blast radius

  description = "Backup administrator role with permission boundary preventing vault/plan/recovery-point deletion"

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-backup-admin"
    Purpose = "backup-administration"
    Tier    = "operator"
  })
}

# Attach the boundary policy as the identity-based policy; effective permissions
# are the intersection, which equals the boundary allowances.
resource "aws_iam_role_policy_attachment" "backup_admin_policy" {
  role       = aws_iam_role.backup_admin.name
  policy_arn = aws_iam_policy.backup_admin_boundary.arn
}

# ---------------------------------------------------------------------------
# 3. Break-Glass Role — Emergency operations only
#    Excluded from deny conditions in the boundary above.
#    Requires MFA within a 15-minute authentication window.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "backup_break_glass_assume_role" {
  statement {
    sid     = "AllowAssumeRoleWithFreshMFA"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "aws:MultiFactorAuthAge"
      values   = ["900"] # 15-minute MFA window
    }
  }
}

resource "aws_iam_role" "backup_break_glass" {
  name                 = "${local.name_prefix}-backup-break-glass"
  assume_role_policy   = data.aws_iam_policy_document.backup_break_glass_assume_role.json
  max_session_duration = 900 # 15 minutes — minimal window for emergency actions

  description = "BREAK-GLASS: Emergency backup role excluded from destructive-action deny. Requires MFA + recent auth."

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-backup-break-glass"
    Purpose = "break-glass-emergency"
    Tier    = "break-glass"
  })
}

# Minimal emergency policy — destructive operations plus read access
resource "aws_iam_role_policy" "backup_break_glass_policy" {
  name = "${local.name_prefix}-break-glass-policy"
  role = aws_iam_role.backup_break_glass.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BackupFullRead"
        Effect   = "Allow"
        Action   = ["backup:Describe*", "backup:Get*", "backup:List*"]
        Resource = "*"
      },
      {
        Sid    = "BackupEmergencyOperations"
        Effect = "Allow"
        Action = [
          "backup:DeleteRecoveryPoint",    # Remove stale test recovery points
          "backup:StopBackupJob",           # Cancel runaway jobs
          "backup:DeleteBackupVault",       # Last-resort vault cleanup (empty only)
          "backup:DeleteBackupPlan",        # Remove orphaned plans
          "backup:DeleteBackupSelection",
        ]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Alarm — Alert on break-glass role assumption
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "break_glass_role_assumed" {
  alarm_name          = "${local.name_prefix}-break-glass-role-assumed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CallCount"
  namespace           = "AWS/IAM"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "ALERT: Break-glass backup role was assumed — verify this is an authorised emergency action"
  treat_missing_data  = "notBreaching"

  dimensions = {
    RoleArn = aws_iam_role.backup_break_glass.arn
  }

  alarm_actions = [aws_sns_topic.backup_notifications.arn]
  ok_actions    = []

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-break-glass-role-assumed"
    Purpose = "security-monitoring"
  })
}

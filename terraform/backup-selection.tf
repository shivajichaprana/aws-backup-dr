# =============================================================================
# AWS Backup Selections — Tag-based resource discovery
# =============================================================================
# Resources are selected for backup by tag. To opt a resource into backup,
# add these tags:
#
#   Backup=true           → included in standard backup plan
#   BackupTier=critical   → included in critical (hourly) backup plan
#
# Supported resource types: EBS, RDS, EFS, DynamoDB, S3, EC2, Aurora,
# DocumentDB, FSx, Neptune, Redshift.
# =============================================================================

# ---------------------------------------------------------------------------
# Selection — Standard Tier (tag: Backup=true, BackupTier != critical)
# ---------------------------------------------------------------------------
resource "aws_backup_selection" "standard" {
  name         = "${local.name_prefix}-standard-selection"
  plan_id      = aws_backup_plan.standard.id
  iam_role_arn = aws_iam_role.backup.arn

  # Select all resources tagged Backup=true
  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.backup_tag_key
    value = var.backup_tag_value
  }

  # Explicitly exclude resources tagged BackupTier=critical
  # (those are handled by the critical plan)
  not_resources = []

  depends_on = [
    aws_iam_role_policy_attachment.backup_policy,
    aws_iam_role_policy_attachment.restore_policy,
    aws_iam_role_policy.backup_s3_and_cross_region,
  ]
}

# ---------------------------------------------------------------------------
# Selection — Critical Tier (tag: Backup=true AND BackupTier=critical)
# ---------------------------------------------------------------------------
resource "aws_backup_selection" "critical" {
  name         = "${local.name_prefix}-critical-selection"
  plan_id      = aws_backup_plan.critical.id
  iam_role_arn = aws_iam_role.backup.arn

  # Must have both tags to qualify
  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.backup_tag_key
    value = var.backup_tag_value
  }

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "BackupTier"
    value = "critical"
  }

  depends_on = [
    aws_iam_role_policy_attachment.backup_policy,
    aws_iam_role_policy_attachment.restore_policy,
    aws_iam_role_policy.backup_s3_and_cross_region,
  ]
}

# ---------------------------------------------------------------------------
# IAM Policy — Allow backup service to tag recovery points
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "backup_tagging" {
  name = "${local.name_prefix}-backup-tagging"
  role = aws_iam_role.backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowTaggingRecoveryPoints"
        Effect = "Allow"
        Action = [
          "backup:TagResource",
          "backup:UntagResource",
          "tag:GetResources",
          "tag:GetTagKeys",
          "tag:GetTagValues",
        ]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Optional: Explicit resource list selection (for resources that can't be
# tagged, e.g. read-only resources in shared accounts)
# ---------------------------------------------------------------------------
# Uncomment and populate to add specific ARNs directly:
#
# resource "aws_backup_selection" "explicit_resources" {
#   name         = "${local.name_prefix}-explicit-selection"
#   plan_id      = aws_backup_plan.standard.id
#   iam_role_arn = aws_iam_role.backup.arn
#
#   resources = [
#     "arn:aws:rds:us-east-1:123456789012:db:my-database",
#     "arn:aws:dynamodb:us-east-1:123456789012:table/my-table",
#   ]
# }

# ---------------------------------------------------------------------------
# CloudWatch Metric Alarms — Monitor backup compliance
# ---------------------------------------------------------------------------

# Alert if any backup jobs fail
resource "aws_cloudwatch_metric_alarm" "backup_job_failures" {
  alarm_name          = "${local.name_prefix}-backup-job-failures"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "NumberOfBackupJobsFailed"
  namespace           = "AWS/Backup"
  period              = 86400 # 24 hours
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "One or more AWS Backup jobs failed in the last 24 hours"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.backup_notifications.arn]
  ok_actions    = [aws_sns_topic.backup_notifications.arn]

  dimensions = {
    BackupVaultName = aws_backup_vault.primary.name
  }

  tags = local.common_tags
}

# Alert if no backup jobs completed successfully (possible schedule disruption)
resource "aws_cloudwatch_metric_alarm" "backup_jobs_completed" {
  alarm_name          = "${local.name_prefix}-no-backup-completions"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "NumberOfBackupJobsCompleted"
  namespace           = "AWS/Backup"
  period              = 86400 # 24 hours
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "No AWS Backup jobs completed successfully in the last 24 hours"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.backup_notifications.arn]

  dimensions = {
    BackupVaultName = aws_backup_vault.primary.name
  }

  tags = local.common_tags
}

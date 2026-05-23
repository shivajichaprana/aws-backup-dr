# =============================================================================
# Backup Reporter — weekly backup-status report Lambda + schedule
# =============================================================================
# Where restore-tester.tf proves recovery points are *usable*, this file proves
# backups are *happening*. A scheduled Lambda summarises the trailing week of
# AWS Backup activity (backup jobs, cross-region copy jobs, and restore-test
# jobs), publishes a human-readable report to the shared SNS topic, and emits
# CloudWatch metrics so the report itself can be alarmed on.
# =============================================================================

# ---------------------------------------------------------------------------
# Variables specific to the reporter (kept local to this feature)
# ---------------------------------------------------------------------------
variable "enable_backup_reporter" {
  description = "Whether to provision the weekly backup status reporter"
  type        = bool
  default     = true
}

variable "backup_report_schedule" {
  description = "EventBridge schedule expression for the weekly backup report (UTC)"
  type        = string
  default     = "cron(0 8 ? * MON *)" # 08:00 UTC every Monday

  validation {
    condition     = can(regex("^(cron|rate)\\(.*\\)$", var.backup_report_schedule))
    error_message = "backup_report_schedule must be a valid cron() or rate() expression."
  }
}

variable "report_window_days" {
  description = "How many trailing days of backup activity each report covers"
  type        = number
  default     = 7

  validation {
    condition     = var.report_window_days >= 1 && var.report_window_days <= 90
    error_message = "report_window_days must be between 1 and 90."
  }
}

variable "reporter_lambda_timeout" {
  description = "Lambda timeout in seconds for the reporter (list calls can paginate)"
  type        = number
  default     = 120

  validation {
    condition     = var.reporter_lambda_timeout >= 30 && var.reporter_lambda_timeout <= 900
    error_message = "reporter_lambda_timeout must be between 30 and 900 seconds."
  }
}

variable "reporter_max_failures_listed" {
  description = "Maximum number of individual job failures enumerated in a single report"
  type        = number
  default     = 20

  validation {
    condition     = var.reporter_max_failures_listed >= 1 && var.reporter_max_failures_listed <= 200
    error_message = "reporter_max_failures_listed must be between 1 and 200."
  }
}

locals {
  reporter_name      = "${local.name_prefix}-backup-reporter"
  reporter_namespace = "BackupDR/Reporting"
}

# ---------------------------------------------------------------------------
# Package the Lambda source
# ---------------------------------------------------------------------------
data "archive_file" "backup_reporter" {
  count       = var.enable_backup_reporter ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/../lambda/backup-reporter"
  output_path = "${path.module}/.build/backup-reporter.zip"
}

# ---------------------------------------------------------------------------
# Dead-letter queue for asynchronous invocation failures
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "backup_reporter_dlq" {
  count = var.enable_backup_reporter ? 1 : 0

  name                       = "${local.reporter_name}-dlq"
  kms_master_key_id          = aws_kms_key.backup_primary.id
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = var.reporter_lambda_timeout * 6
  sqs_managed_sse_enabled    = false

  tags = merge(local.common_tags, {
    Name      = "${local.reporter_name}-dlq"
    Component = "reporting"
  })
}

# ---------------------------------------------------------------------------
# Lambda execution role + least-privilege policy
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "backup_reporter_assume" {
  count = var.enable_backup_reporter ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup_reporter" {
  count              = var.enable_backup_reporter ? 1 : 0
  name               = "${local.reporter_name}-role"
  assume_role_policy = data.aws_iam_policy_document.backup_reporter_assume[0].json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "backup_reporter_policy" {
  count = var.enable_backup_reporter ? 1 : 0

  # --- AWS Backup: read-only job listings -------------------------------
  statement {
    sid    = "ReadBackupJobs"
    effect = "Allow"
    actions = [
      "backup:ListBackupJobs",
      "backup:ListCopyJobs",
      "backup:ListRestoreJobs",
      "backup:ListBackupVaults",
      "backup:DescribeBackupVault",
    ]
    resources = ["*"]
  }

  # --- Publish the report to the shared SNS topic ------------------------
  statement {
    sid       = "PublishReport"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.backup_notifications.arn]
  }

  # --- KMS to publish to the KMS-encrypted SNS topic ---------------------
  statement {
    sid    = "KmsForSnsPublish"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.backup_primary.arn]
  }

  # --- Telemetry ---------------------------------------------------------
  statement {
    sid       = "PublishMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.reporter_namespace]
    }
  }

  # --- DLQ ---------------------------------------------------------------
  statement {
    sid       = "DeadLetterQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.backup_reporter_dlq[0].arn]
  }

  # --- Logging -----------------------------------------------------------
  statement {
    sid    = "Logging"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.backup_reporter[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "backup_reporter" {
  count  = var.enable_backup_reporter ? 1 : 0
  name   = "${local.reporter_name}-policy"
  role   = aws_iam_role.backup_reporter[0].id
  policy = data.aws_iam_policy_document.backup_reporter_policy[0].json
}

# ---------------------------------------------------------------------------
# Log group (created explicitly so retention is managed by Terraform)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "backup_reporter" {
  count             = var.enable_backup_reporter ? 1 : 0
  name              = "/aws/lambda/${local.reporter_name}"
  retention_in_days = 90
  tags              = local.common_tags
}

# ---------------------------------------------------------------------------
# The Lambda function
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "backup_reporter" {
  count = var.enable_backup_reporter ? 1 : 0

  function_name    = local.reporter_name
  description      = "Weekly AWS Backup status report: backup, copy, and restore jobs -> SNS"
  role             = aws_iam_role.backup_reporter[0].arn
  handler          = "app.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = var.reporter_lambda_timeout
  memory_size      = 256
  filename         = data.archive_file.backup_reporter[0].output_path
  source_code_hash = data.archive_file.backup_reporter[0].output_base64sha256

  reserved_concurrent_executions = 1

  dead_letter_config {
    target_arn = aws_sqs_queue.backup_reporter_dlq[0].arn
  }

  environment {
    variables = {
      SNS_TOPIC_ARN       = aws_sns_topic.backup_notifications.arn
      CW_NAMESPACE        = local.reporter_namespace
      REPORT_WINDOW_DAYS  = tostring(var.report_window_days)
      MAX_FAILURES_LISTED = tostring(var.reporter_max_failures_listed)
      ENVIRONMENT         = var.environment
      PROJECT_NAME        = var.project_name
      LOG_LEVEL           = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_iam_role_policy.backup_reporter,
    aws_cloudwatch_log_group.backup_reporter,
  ]

  tags = merge(local.common_tags, {
    Name      = local.reporter_name
    Component = "reporting"
  })
}

# ---------------------------------------------------------------------------
# Weekly schedule -> invoke the reporter Lambda directly
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "backup_report_schedule" {
  count               = var.enable_backup_reporter ? 1 : 0
  name                = "${local.reporter_name}-weekly"
  description         = "Triggers the weekly AWS Backup status report"
  schedule_expression = var.backup_report_schedule
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "backup_report_schedule" {
  count     = var.enable_backup_reporter ? 1 : 0
  rule      = aws_cloudwatch_event_rule.backup_report_schedule[0].name
  target_id = "InvokeBackupReporter"
  arn       = aws_lambda_function.backup_reporter[0].arn
}

resource "aws_lambda_permission" "allow_eventbridge_reporter" {
  count         = var.enable_backup_reporter ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_reporter[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_report_schedule[0].arn
}

# ---------------------------------------------------------------------------
# Alarm: the reporter Lambda itself errored (so a silent reporter is noticed)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "backup_reporter_errors" {
  count = var.enable_backup_reporter ? 1 : 0

  alarm_name          = "${local.reporter_name}-errors"
  alarm_description   = "The weekly backup reporter Lambda failed to run."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.backup_reporter[0].function_name
  }

  alarm_actions = [aws_sns_topic.backup_notifications.arn]
  ok_actions    = [aws_sns_topic.backup_notifications.arn]
  tags          = local.common_tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "backup_reporter_lambda_arn" {
  description = "ARN of the weekly backup-reporter Lambda function"
  value       = try(aws_lambda_function.backup_reporter[0].arn, null)
}

output "backup_reporter_schedule" {
  description = "Schedule expression driving the weekly backup report"
  value       = var.enable_backup_reporter ? var.backup_report_schedule : null
}

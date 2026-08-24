# =============================================================================
# Restore Testing — Lambda worker, IAM, DLQ, and weekly schedule
# =============================================================================
# "Untested backups are not backups." This file provisions the compute and the
# weekly trigger for the automated restore-testing workflow. The Lambda defined
# here is invoked by the Step Functions state machine in restore-workflow.tf;
# the EventBridge schedule below starts that state machine once per week.
# =============================================================================

# ---------------------------------------------------------------------------
# Variables specific to restore testing (kept local to this feature)
# ---------------------------------------------------------------------------
variable "enable_restore_testing" {
  description = "Whether to provision the automated restore-testing workflow"
  type        = bool
  default     = true
}

variable "restore_test_schedule" {
  description = "EventBridge schedule expression for the weekly restore test (UTC)"
  type        = string
  default     = "cron(0 3 ? * SUN *)" # 03:00 UTC every Sunday

  validation {
    condition     = can(regex("^(cron|rate)\\(.*\\)$", var.restore_test_schedule))
    error_message = "restore_test_schedule must be a valid cron() or rate() expression."
  }
}

variable "restore_test_lookback_days" {
  description = "Only recovery points created within this many days are eligible for testing"
  type        = number
  default     = 7

  validation {
    condition     = var.restore_test_lookback_days >= 1 && var.restore_test_lookback_days <= 90
    error_message = "restore_test_lookback_days must be between 1 and 90."
  }
}

variable "restore_test_role_arn" {
  description = "Optional cross-account IAM role ARN assumed for sandbox restores. Empty = restore in this account."
  type        = string
  default     = ""

  validation {
    condition     = var.restore_test_role_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.restore_test_role_arn))
    error_message = "restore_test_role_arn must be empty or a valid IAM role ARN."
  }
}

variable "restore_test_lambda_timeout" {
  description = "Lambda timeout in seconds for each restore-test action invocation"
  type        = number
  default     = 120

  validation {
    condition     = var.restore_test_lambda_timeout >= 30 && var.restore_test_lambda_timeout <= 900
    error_message = "restore_test_lambda_timeout must be between 30 and 900 seconds."
  }
}

variable "restore_test_supported_types" {
  description = "AWS Backup resource types eligible for automated restore testing"
  type        = list(string)
  default     = ["EBS", "RDS", "DynamoDB", "EFS"]
}

locals {
  restore_tester_name = "${local.name_prefix}-restore-tester"
  # Render the supported-types list as the CSV the Lambda expects.
  restore_supported_csv = join(",", var.restore_test_supported_types)
}

# ---------------------------------------------------------------------------
# Package the Lambda source
# ---------------------------------------------------------------------------
data "archive_file" "restore_tester" {
  count       = var.enable_restore_testing ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/../lambda/restore-tester"
  output_path = "${path.module}/.build/restore-tester.zip"
}

# ---------------------------------------------------------------------------
# Dead-letter queue for asynchronous invocation failures
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "restore_tester_dlq" {
  count = var.enable_restore_testing ? 1 : 0

  name                       = "${local.restore_tester_name}-dlq"
  kms_master_key_id          = aws_kms_key.backup_primary.id
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = var.restore_test_lambda_timeout * 6
  sqs_managed_sse_enabled    = false

  tags = merge(local.common_tags, {
    Name      = "${local.restore_tester_name}-dlq"
    Component = "restore-testing"
  })
}

# ---------------------------------------------------------------------------
# Lambda execution role + least-privilege policy
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "restore_tester_assume" {
  count = var.enable_restore_testing ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "restore_tester" {
  count              = var.enable_restore_testing ? 1 : 0
  name               = "${local.restore_tester_name}-role"
  assume_role_policy = data.aws_iam_policy_document.restore_tester_assume[0].json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "restore_tester_policy" {
  count = var.enable_restore_testing ? 1 : 0

  # --- AWS Backup: read recovery points + drive restore jobs -------------
  statement {
    sid    = "BackupRestoreOperations"
    effect = "Allow"
    actions = [
      "backup:ListRecoveryPointsByBackupVault",
      "backup:DescribeRecoveryPoint",
      "backup:ListBackupVaults",
      "backup:DescribeBackupVault",
      "backup:StartRestoreJob",
      "backup:DescribeRestoreJob",
      "backup:ListRestoreJobs",
      "backup:GetRecoveryPointRestoreMetadata",
    ]
    resources = ["*"]
  }

  # --- Verify + teardown restored resources (in-account fallback) --------
  statement {
    sid    = "VerifyAndTeardownResources"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DeleteVolume",
      "rds:DescribeDBInstances",
      "rds:DeleteDBInstance",
      "dynamodb:DescribeTable",
      "dynamodb:DeleteTable",
      "elasticfilesystem:DescribeFileSystems",
      "elasticfilesystem:DeleteFileSystem",
    ]
    resources = ["*"]
  }

  # --- Cross-account: assume the sandbox restore role --------------------
  dynamic "statement" {
    for_each = var.restore_test_role_arn != "" ? [1] : []
    content {
      sid       = "AssumeSandboxRole"
      effect    = "Allow"
      actions   = ["sts:AssumeRole"]
      resources = [var.restore_test_role_arn]
    }
  }

  # --- Pass the AWS Backup role to the restore job -----------------------
  statement {
    sid       = "PassBackupRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.backup.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["backup.amazonaws.com"]
    }
  }

  # --- KMS for encrypted restores + DLQ ----------------------------------
  statement {
    sid    = "KmsForRestore"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = [
      aws_kms_key.backup_primary.arn,
      aws_kms_key.backup_dr.arn,
    ]
  }

  # --- Telemetry ----------------------------------------------------------
  statement {
    sid       = "PublishMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["BackupDR/RestoreTesting"]
    }
  }

  # --- DLQ ----------------------------------------------------------------
  statement {
    sid       = "DeadLetterQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.restore_tester_dlq[0].arn]
  }

  # --- Logging ------------------------------------------------------------
  statement {
    sid    = "Logging"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.restore_tester[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "restore_tester" {
  count  = var.enable_restore_testing ? 1 : 0
  name   = "${local.restore_tester_name}-policy"
  role   = aws_iam_role.restore_tester[0].id
  policy = data.aws_iam_policy_document.restore_tester_policy[0].json
}

# ---------------------------------------------------------------------------
# Log group (created explicitly so retention is managed by Terraform)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "restore_tester" {
  count             = var.enable_restore_testing ? 1 : 0
  name              = "/aws/lambda/${local.restore_tester_name}"
  retention_in_days = 90
  # Encrypted at rest with the CloudWatch Logs AWS-managed key. The backup CMK
  # is intentionally not used here: its key policy scopes usage to the AWS
  # Backup service principal only, and CloudWatch Logs requires an explicit
  # key-policy grant that we keep out of the ransomware-hardened backup CMK.
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# The Lambda function
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "restore_tester" {
  count = var.enable_restore_testing ? 1 : 0

  function_name    = local.restore_tester_name
  description      = "Weekly automated restore test: select, restore, verify, teardown, report"
  role             = aws_iam_role.restore_tester[0].arn
  handler          = "app.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = var.restore_test_lambda_timeout
  memory_size      = 256
  filename         = data.archive_file.restore_tester[0].output_path
  source_code_hash = data.archive_file.restore_tester[0].output_base64sha256

  reserved_concurrent_executions = 2

  dead_letter_config {
    target_arn = aws_sqs_queue.restore_tester_dlq[0].arn
  }

  environment {
    variables = {
      BACKUP_VAULT_NAME        = aws_backup_vault.primary.name
      BACKUP_RESTORE_ROLE_ARN  = aws_iam_role.backup.arn
      RESTORE_TEST_ROLE_ARN    = var.restore_test_role_arn
      LOOKBACK_DAYS            = tostring(var.restore_test_lookback_days)
      CW_NAMESPACE             = "BackupDR/RestoreTesting"
      SNS_TOPIC_ARN            = aws_sns_topic.backup_notifications.arn
      ENVIRONMENT              = var.environment
      SUPPORTED_RESOURCE_TYPES = local.restore_supported_csv
      LOG_LEVEL                = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_iam_role_policy.restore_tester,
    aws_cloudwatch_log_group.restore_tester,
  ]

  tags = merge(local.common_tags, {
    Name      = local.restore_tester_name
    Component = "restore-testing"
  })
}

# ---------------------------------------------------------------------------
# Weekly schedule -> Step Functions state machine (defined in restore-workflow.tf)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "restore_test_schedule" {
  count               = var.enable_restore_testing ? 1 : 0
  name                = "${local.restore_tester_name}-weekly"
  description         = "Triggers the weekly automated backup restore test"
  schedule_expression = var.restore_test_schedule
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "restore_test_schedule" {
  count     = var.enable_restore_testing ? 1 : 0
  rule      = aws_cloudwatch_event_rule.restore_test_schedule[0].name
  target_id = "StartRestoreTestStateMachine"
  arn       = aws_sfn_state_machine.restore_test[0].arn
  role_arn  = aws_iam_role.restore_test_events[0].arn

  # Seed the execution with a fresh test id derived from the scheduled time.
  input_transformer {
    input_paths = {
      time = "$.time"
    }
    input_template = <<-TEMPLATE
      {"action": "select", "context": {"trigger_time": <time>}}
    TEMPLATE
  }
}

# Role allowing EventBridge to start a Step Functions execution
data "aws_iam_policy_document" "restore_test_events_assume" {
  count = var.enable_restore_testing ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "restore_test_events" {
  count              = var.enable_restore_testing ? 1 : 0
  name               = "${local.restore_tester_name}-events-role"
  assume_role_policy = data.aws_iam_policy_document.restore_test_events_assume[0].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "restore_test_events" {
  count = var.enable_restore_testing ? 1 : 0
  name  = "${local.restore_tester_name}-events-policy"
  role  = aws_iam_role.restore_test_events[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartExecution"
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.restore_test[0].arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Alarm: a restore test failed
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "restore_test_failure" {
  count = var.enable_restore_testing ? 1 : 0

  alarm_name          = "${local.restore_tester_name}-failure"
  alarm_description   = "A weekly automated restore test failed verification or errored."
  namespace           = "BackupDR/RestoreTesting"
  metric_name         = "RestoreTestFailure"
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    Environment = var.environment
  }

  alarm_actions = [aws_sns_topic.backup_notifications.arn]
  ok_actions    = [aws_sns_topic.backup_notifications.arn]
  tags          = local.common_tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "restore_tester_lambda_arn" {
  description = "ARN of the restore-tester Lambda function"
  value       = try(aws_lambda_function.restore_tester[0].arn, null)
}

output "restore_tester_dlq_url" {
  description = "URL of the restore-tester dead-letter queue"
  value       = try(aws_sqs_queue.restore_tester_dlq[0].url, null)
}

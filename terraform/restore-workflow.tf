# =============================================================================
# Restore Testing — Step Functions orchestration
# =============================================================================
# Orchestrates the full restore-test lifecycle:
#
#   Select -> Restore -> (Wait/Poll loop) -> Verify -> Teardown -> Report -> Notify
#
# Every failure path funnels through Teardown + Report + Notify so that:
#   (a) we never leak a restored resource (cost / blast-radius), and
#   (b) a failed test always emits the RestoreTestFailure metric that the
#       alarm in restore-tester.tf watches.
#
# State I/O contract: each Task passes {"action": "...", "context": <ctx>} to
# the Lambda and replaces the whole state with the Lambda's return value (which
# always echoes an updated "context"). Catch handlers use ResultPath "$.error"
# so the threaded context survives onto the failure path.
# =============================================================================

# ---------------------------------------------------------------------------
# Log group for the state machine
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "restore_workflow" {
  count             = var.enable_restore_testing ? 1 : 0
  name              = "/aws/vendedlogs/states/${local.restore_tester_name}"
  retention_in_days = 90
  # Default CloudWatch Logs encryption (see note in restore-tester.tf).
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# IAM role for the state machine
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "restore_sfn_assume" {
  count = var.enable_restore_testing ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "restore_sfn" {
  count              = var.enable_restore_testing ? 1 : 0
  name               = "${local.restore_tester_name}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.restore_sfn_assume[0].json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "restore_sfn_policy" {
  count = var.enable_restore_testing ? 1 : 0

  statement {
    sid     = "InvokeWorker"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.restore_tester[0].arn,
      "${aws_lambda_function.restore_tester[0].arn}:*",
    ]
  }

  statement {
    sid       = "NotifyResults"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.backup_notifications.arn]
  }

  # Allow the SNS publish to use the KMS-encrypted topic.
  statement {
    sid    = "KmsForSns"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.backup_primary.arn]
  }

  # CloudWatch Logs delivery for Step Functions logging configuration.
  statement {
    sid    = "StateMachineLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  # X-Ray tracing.
  statement {
    sid    = "XRayTracing"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "restore_sfn" {
  count  = var.enable_restore_testing ? 1 : 0
  name   = "${local.restore_tester_name}-sfn-policy"
  role   = aws_iam_role.restore_sfn[0].id
  policy = data.aws_iam_policy_document.restore_sfn_policy[0].json
}

# ---------------------------------------------------------------------------
# Reusable retry block for transient Lambda faults
# ---------------------------------------------------------------------------
locals {
  restore_lambda_retry = [
    {
      ErrorEquals = [
        "Lambda.ServiceException",
        "Lambda.AWSLambdaException",
        "Lambda.SdkClientException",
        "Lambda.TooManyRequestsException",
      ]
      IntervalSeconds = 5
      MaxAttempts     = 4
      BackoffRate     = 2.0
    },
  ]

  restore_state_machine_definition = jsonencode({
    Comment = "Weekly automated AWS Backup restore test with mandatory teardown."
    StartAt = "SelectRecoveryPoint"
    States = {
      # ---- Select --------------------------------------------------------
      SelectRecoveryPoint = {
        Type     = "Task"
        Resource = aws_lambda_function.restore_tester[0].arn
        Parameters = {
          "action"    = "select"
          "context.$" = "$.context"
        }
        ResultPath = "$"
        Retry      = local.restore_lambda_retry
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "ReportFailure"
            ResultPath  = "$.error"
          },
        ]
        Next = "RecoveryPointAvailable?"
      }

      "RecoveryPointAvailable?" = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.action_result"
            StringEquals = "no_recovery_points"
            Next         = "NoRecoveryPoints"
          },
        ]
        Default = "StartRestore"
      }

      NoRecoveryPoints = {
        Type    = "Succeed"
        Comment = "No eligible recovery points in the look-back window; nothing to test."
      }

      # ---- Restore -------------------------------------------------------
      StartRestore = {
        Type     = "Task"
        Resource = aws_lambda_function.restore_tester[0].arn
        Parameters = {
          "action"    = "restore"
          "context.$" = "$.context"
        }
        ResultPath = "$"
        Retry      = local.restore_lambda_retry
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "TeardownOnFailure"
            ResultPath  = "$.error"
          },
        ]
        Next = "WaitForRestore"
      }

      WaitForRestore = {
        Type    = "Wait"
        Seconds = 60
        Next    = "CheckRestoreStatus"
      }

      CheckRestoreStatus = {
        Type     = "Task"
        Resource = aws_lambda_function.restore_tester[0].arn
        Parameters = {
          "action"    = "status"
          "context.$" = "$.context"
        }
        ResultPath = "$"
        Retry      = local.restore_lambda_retry
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "TeardownOnFailure"
            ResultPath  = "$.error"
          },
        ]
        Next = "RestoreComplete?"
      }

      "RestoreComplete?" = {
        Type = "Choice"
        Choices = [
          {
            Variable      = "$.is_complete"
            BooleanEquals = true
            Next          = "VerifyIntegrity"
          },
          {
            Variable                 = "$.context.details.poll_count"
            NumericGreaterThanEquals = 60
            Next                     = "TeardownOnFailure"
          },
        ]
        Default = "WaitForRestore"
      }

      # ---- Verify --------------------------------------------------------
      VerifyIntegrity = {
        Type     = "Task"
        Resource = aws_lambda_function.restore_tester[0].arn
        Parameters = {
          "action"    = "verify"
          "context.$" = "$.context"
        }
        ResultPath = "$"
        Retry      = local.restore_lambda_retry
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "TeardownOnFailure"
            ResultPath  = "$.error"
          },
        ]
        Next = "Teardown"
      }

      # ---- Teardown (success path) --------------------------------------
      Teardown = {
        Type     = "Task"
        Resource = aws_lambda_function.restore_tester[0].arn
        Parameters = {
          "action"    = "teardown"
          "context.$" = "$.context"
        }
        ResultPath = "$"
        Retry      = local.restore_lambda_retry
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "ReportSuccess"
            ResultPath  = "$.error"
          },
        ]
        Next = "ReportSuccess"
      }

      ReportSuccess = {
        Type     = "Task"
        Resource = aws_lambda_function.restore_tester[0].arn
        Parameters = {
          "action"    = "report"
          "context.$" = "$.context"
        }
        ResultPath = "$"
        Retry      = local.restore_lambda_retry
        Next       = "NotifySuccess"
      }

      NotifySuccess = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.backup_notifications.arn
          Subject     = "[backup-dr] Restore test PASSED"
          "Message.$" = "States.JsonToString($.summary)"
        }
        Next = "TestSucceeded"
      }

      TestSucceeded = {
        Type = "Succeed"
      }

      # ---- Failure path --------------------------------------------------
      TeardownOnFailure = {
        Type     = "Task"
        Resource = aws_lambda_function.restore_tester[0].arn
        Parameters = {
          "action"    = "teardown"
          "context.$" = "$.context"
        }
        ResultPath = "$"
        Retry      = local.restore_lambda_retry
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "ReportFailure"
            ResultPath  = "$.error"
          },
        ]
        Next = "ReportFailure"
      }

      ReportFailure = {
        Type     = "Task"
        Resource = aws_lambda_function.restore_tester[0].arn
        Parameters = {
          "action"    = "report"
          "context.$" = "$.context"
        }
        ResultPath = "$"
        Retry      = local.restore_lambda_retry
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "NotifyFailure"
            ResultPath  = "$.error"
          },
        ]
        Next = "NotifyFailure"
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.backup_notifications.arn
          Subject     = "[backup-dr] Restore test FAILED"
          "Message.$" = "States.JsonToString($)"
        }
        Next = "TestFailed"
      }

      TestFailed = {
        Type  = "Fail"
        Error = "RestoreTestFailed"
        Cause = "The automated restore test did not complete successfully. See execution history and CloudWatch metrics."
      }
    }
  })
}

# ---------------------------------------------------------------------------
# The state machine
# ---------------------------------------------------------------------------
resource "aws_sfn_state_machine" "restore_test" {
  count = var.enable_restore_testing ? 1 : 0

  name     = "${local.restore_tester_name}-workflow"
  role_arn = aws_iam_role.restore_sfn[0].arn
  type     = "STANDARD"

  definition = local.restore_state_machine_definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.restore_workflow[0].arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [aws_iam_role_policy.restore_sfn]

  tags = merge(local.common_tags, {
    Name      = "${local.restore_tester_name}-workflow"
    Component = "restore-testing"
  })
}

output "restore_test_state_machine_arn" {
  description = "ARN of the restore-test Step Functions state machine"
  value       = try(aws_sfn_state_machine.restore_test[0].arn, null)
}

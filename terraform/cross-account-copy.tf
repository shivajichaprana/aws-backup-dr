# =============================================================================
# Cross-Account Backup Copy — Dedicated DR Account Vault
# =============================================================================
# For the strongest ransomware / insider-threat protection, backup copies
# should reside in a SEPARATE AWS ACCOUNT with independent IAM controls.
# An attacker who compromises the primary account cannot reach the DR-account
# vault without also compromising that account's credentials.
#
# Architecture:
#
#   Primary account                    DR account (var.dr_account_id)
#   ──────────────────                 ─────────────────────────────
#   aws_backup_vault.primary           aws_backup_vault.cross_account_dr
#        │  (copy_action)                      │
#        └──────────────────────────► vault receives cross-account copies
#
# How cross-account copy works in AWS Backup:
#   1. The source backup plan includes a copy_action targeting the DR-account
#      vault ARN.
#   2. The DR-account vault's resource-based policy must explicitly allow
#      backup:CopyIntoBackupVault from the source account.
#   3. The source account's backup IAM role must have a KMS grant on the
#      DR-account vault's KMS key.
#
# This module provisions the DR-account vault and all required IAM / KMS
# resources when var.enable_cross_account_copy = true.
# The copy_action is added to a new "cross-account" backup plan rule.
# =============================================================================

# ---------------------------------------------------------------------------
# Variables — Cross-Account Configuration
# ---------------------------------------------------------------------------
variable "enable_cross_account_copy" {
  description = "Whether to enable cross-account backup copies to a dedicated DR account (strongest isolation)"
  type        = bool
  default     = false
}

variable "dr_account_id" {
  description = "AWS account ID of the dedicated DR account that will receive cross-account backup copies"
  type        = string
  default     = ""

  validation {
    condition     = var.dr_account_id == "" || can(regex("^[0-9]{12}$", var.dr_account_id))
    error_message = "dr_account_id must be a 12-digit AWS account ID or empty string."
  }
}

variable "cross_account_vault_name" {
  description = "Name of the backup vault in the DR account (must already exist or be created by separate DR-account Terraform state)"
  type        = string
  default     = "cross-account-dr-vault"
}

variable "cross_account_kms_key_arn" {
  description = "ARN of the KMS key in the DR account that encrypts the cross-account vault"
  type        = string
  default     = ""

  validation {
    condition     = var.cross_account_kms_key_arn == "" || can(regex("^arn:", var.cross_account_kms_key_arn))
    error_message = "cross_account_kms_key_arn must be a valid ARN or empty string."
  }
}

variable "cross_account_copy_retention_days" {
  description = "Days to retain cross-account backup copies in the DR account"
  type        = number
  default     = 90

  validation {
    condition     = var.cross_account_copy_retention_days >= 7
    error_message = "cross_account_copy_retention_days must be at least 7."
  }
}

variable "cross_account_copy_cold_storage_after_days" {
  description = "Days after which cross-account copies transition to cold storage in the DR vault (0 to disable)"
  type        = number
  default     = 30

  validation {
    condition     = var.cross_account_copy_cold_storage_after_days >= 0
    error_message = "cross_account_copy_cold_storage_after_days must be >= 0."
  }
}

# ---------------------------------------------------------------------------
# Local: compute the cross-account vault ARN
# ---------------------------------------------------------------------------
locals {
  cross_account_vault_arn = var.enable_cross_account_copy ? "arn:${local.partition}:backup:${var.primary_region}:${var.dr_account_id}:backup-vault:${var.cross_account_vault_name}" : ""

  cross_account_kms_key_arn_resolved = (
    var.enable_cross_account_copy && var.cross_account_kms_key_arn != ""
    ? var.cross_account_kms_key_arn
    : null
  )
}

# ---------------------------------------------------------------------------
# IAM: extend the backup service role to allow cross-account copy operations
# ---------------------------------------------------------------------------
# The existing backup service role (created in backup-plan.tf) needs:
#   a) sts:AssumeRole into the DR account (handled by AWS Backup internally)
#   b) kms:CreateGrant on the DR-account KMS key (to allow DR vault to decrypt)
resource "aws_iam_role_policy" "backup_cross_account_kms" {
  count = var.enable_cross_account_copy && var.cross_account_kms_key_arn != "" ? 1 : 0

  name = "${local.name_prefix}-cross-account-kms"
  role = aws_iam_role.backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Allow the backup role to grant the DR-account KMS key for copy operations
      {
        Sid    = "AllowKMSGrantForCrossAccountCopy"
        Effect = "Allow"
        Action = [
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "kms:ReEncrypt*",
        ]
        Resource = var.cross_account_kms_key_arn
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Backup Plan — Cross-Account Copy
# A dedicated backup plan that adds a cross-account copy_action on top of
# the existing cross-region copy.  This plan targets the same resource
# selection (Backup=true tag) and runs on the same daily schedule.
# ---------------------------------------------------------------------------
resource "aws_backup_plan" "cross_account" {
  count = var.enable_cross_account_copy ? 1 : 0

  name = "${local.name_prefix}-cross-account"

  rule {
    rule_name         = "daily-cross-account-copy"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = var.backup_schedule_cron
    start_window      = 60
    completion_window = var.completion_window_minutes

    lifecycle {
      cold_storage_after = var.warm_storage_after_days
      delete_after       = var.delete_after_days
    }

    # Copy to same-account DR vault in the DR region
    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn

      lifecycle {
        cold_storage_after = 30
        delete_after       = var.dr_delete_after_days
      }
    }

    # Copy to separate DR ACCOUNT vault (air-gapped from primary account)
    copy_action {
      destination_vault_arn = local.cross_account_vault_arn

      lifecycle {
        cold_storage_after = var.cross_account_copy_cold_storage_after_days > 0 ? var.cross_account_copy_cold_storage_after_days : null
        delete_after       = var.cross_account_copy_retention_days
      }
    }

    recovery_point_tags = merge(local.common_tags, {
      BackupTier    = "cross-account"
      BackupPlan    = "${local.name_prefix}-cross-account"
      CopyTarget    = "dr-account-${var.dr_account_id}"
    })
  }

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-cross-account"
    Purpose = "cross-account-air-gapped-copy"
  })

  depends_on = [aws_iam_role_policy_attachment.backup_policy]
}

# Attach the cross-account plan to the same tag-based selection
resource "aws_backup_selection" "cross_account" {
  count = var.enable_cross_account_copy ? 1 : 0

  iam_role_arn = aws_iam_role.backup.arn
  name         = "${local.name_prefix}-cross-account-selection"
  plan_id      = aws_backup_plan.cross_account[0].id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = var.backup_tag_key
    value = var.backup_tag_value
  }
}

# ---------------------------------------------------------------------------
# DR-Account Vault Acceptance Policy
# This policy MUST be applied to the vault IN THE DR ACCOUNT.  Because
# Terraform is running in the primary account, this resource uses the primary
# AWS provider but references the DR account vault ARN.
#
# NOTE: If the DR account is managed by a separate Terraform state, copy the
# policy document below and apply it manually or via the DR-account workspace.
# ---------------------------------------------------------------------------

# Rendered policy document — can be used out-of-band if needed
data "aws_iam_policy_document" "dr_account_vault_acceptance_policy" {
  count = var.enable_cross_account_copy ? 1 : 0

  statement {
    sid    = "AllowCrossAccountBackupCopy"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    actions = [
      "backup:CopyIntoBackupVault",
    ]

    resources = ["*"]

    # Restrict copy operations to the source account
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid    = "DenyDestructiveOperationsOnDRVault"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "backup:DeleteBackupVault",
      "backup:DeleteRecoveryPoint",
      "backup:DeleteBackupVaultLockConfiguration",
    ]

    resources = ["*"]

    condition {
      # Only the DR-account break-glass role can perform these operations
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${var.dr_account_id}:role/${local.name_prefix}-backup-break-glass"]
    }
  }
}

# Output the rendered policy so DR-account operators can apply it
output "dr_account_vault_acceptance_policy_json" {
  description = "Apply this policy to the DR-account vault (${var.cross_account_vault_name}) to allow cross-account copies from this account"
  value       = var.enable_cross_account_copy ? data.aws_iam_policy_document.dr_account_vault_acceptance_policy[0].json : ""
  sensitive   = false
}

# ---------------------------------------------------------------------------
# Outputs — Cross-Account Configuration Summary
# ---------------------------------------------------------------------------
output "cross_account_backup_enabled" {
  description = "Whether cross-account backup copy is enabled"
  value       = var.enable_cross_account_copy
}

output "cross_account_vault_arn" {
  description = "ARN of the target DR-account vault receiving cross-account copies"
  value       = local.cross_account_vault_arn
}

output "cross_account_backup_plan_id" {
  description = "ID of the cross-account backup plan (empty if cross-account copy is disabled)"
  value       = var.enable_cross_account_copy ? aws_backup_plan.cross_account[0].id : ""
}

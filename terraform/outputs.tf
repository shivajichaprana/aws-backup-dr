# =============================================================================
# Outputs
# =============================================================================

output "backup_vault_primary_arn" {
  description = "ARN of the primary backup vault"
  value       = aws_backup_vault.primary.arn
}

output "backup_vault_primary_name" {
  description = "Name of the primary backup vault"
  value       = aws_backup_vault.primary.name
}

output "backup_vault_dr_arn" {
  description = "ARN of the DR backup vault"
  value       = aws_backup_vault.dr.arn
}

output "backup_vault_dr_name" {
  description = "Name of the DR backup vault"
  value       = aws_backup_vault.dr.name
}

output "kms_key_primary_arn" {
  description = "ARN of the KMS CMK for the primary vault"
  value       = aws_kms_key.backup_primary.arn
}

output "kms_key_dr_arn" {
  description = "ARN of the KMS CMK for the DR vault"
  value       = aws_kms_key.backup_dr.arn
}

output "backup_plan_standard_id" {
  description = "ID of the standard backup plan"
  value       = aws_backup_plan.standard.id
}

output "backup_plan_critical_id" {
  description = "ID of the critical backup plan"
  value       = aws_backup_plan.critical.id
}

output "backup_iam_role_arn" {
  description = "ARN of the IAM role used by AWS Backup"
  value       = aws_iam_role.backup.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for backup alerts"
  value       = aws_sns_topic.backup_notifications.arn
}

output "vault_lock_enabled" {
  description = "Whether vault lock is enabled (compliance mode)"
  value       = var.enable_vault_lock
}

output "tagging_instructions" {
  description = "How to opt resources into backup"
  value = {
    standard_backup = "Add tags: ${var.backup_tag_key}=${var.backup_tag_value}"
    critical_backup = "Add tags: ${var.backup_tag_key}=${var.backup_tag_value}, BackupTier=critical"
  }
}

variable "primary_region" {
  description = "Primary AWS region for backup vaults and resources"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Disaster recovery AWS region for cross-region backup copies"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Deployment environment (production, staging, development)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "environment must be one of: production, staging, development."
  }
}

variable "project_name" {
  description = "Project name used as a prefix for resource names"
  type        = string
  default     = "backup-dr"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric and hyphens, 3-30 chars."
  }
}

variable "kms_deletion_window_in_days" {
  description = "Number of days before KMS CMK is deleted after destroy (7-30)"
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_in_days >= 7 && var.kms_deletion_window_in_days <= 30
    error_message = "kms_deletion_window_in_days must be between 7 and 30."
  }
}

variable "vault_lock_min_retention_days" {
  description = "Minimum retention days enforced by vault lock (compliance mode). Min 1, must be <= max."
  type        = number
  default     = 35

  validation {
    condition     = var.vault_lock_min_retention_days >= 1
    error_message = "vault_lock_min_retention_days must be at least 1."
  }
}

variable "vault_lock_max_retention_days" {
  description = "Maximum retention days enforced by vault lock (compliance mode)"
  type        = number
  default     = 365
}

variable "backup_schedule_cron" {
  description = "Cron expression for the daily backup schedule (UTC)"
  type        = string
  default     = "cron(0 5 * * ? *)"  # 05:00 UTC daily
}

variable "backup_window" {
  description = "Preferred backup window (must not overlap with maintenance windows)"
  type        = string
  default     = "04:00-05:00"
}

variable "completion_window_minutes" {
  description = "Minutes allowed for a backup job to complete before cancellation"
  type        = number
  default     = 120
}

# Lifecycle – warm storage (S3 Standard-IA equivalent in Backup)
variable "warm_storage_after_days" {
  description = "Days after which recovery points transition to cold storage"
  type        = number
  default     = 90
}

# Lifecycle – total retention
variable "delete_after_days" {
  description = "Total days to retain recovery points before deletion"
  type        = number
  default     = 365
}

variable "dr_delete_after_days" {
  description = "Total days to retain cross-region DR copies before deletion"
  type        = number
  default     = 90
}

variable "backup_tag_key" {
  description = "Tag key used to select resources for backup"
  type        = string
  default     = "Backup"
}

variable "backup_tag_value" {
  description = "Tag value used to select resources for backup"
  type        = string
  default     = "true"
}

variable "sns_alert_email" {
  description = "Email address for backup failure alerts (leave empty to skip subscription)"
  type        = string
  default     = ""
}

variable "enable_vault_lock" {
  description = "Whether to enable compliance-mode vault lock (irreversible after 72h grace period)"
  type        = bool
  default     = false  # Set true in production after validating retention settings
}

variable "changeable_for_days" {
  description = "Grace period (days) during which vault lock settings can be changed before becoming permanent. Min 3."
  type        = number
  default     = 3

  validation {
    condition     = var.changeable_for_days >= 3
    error_message = "changeable_for_days must be at least 3 (AWS minimum for vault lock)."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

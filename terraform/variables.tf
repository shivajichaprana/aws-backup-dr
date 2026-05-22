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

# =============================================================================
# Route 53 DNS failover (DR)
# =============================================================================
# These drive terraform/route53-failover.tf and terraform/health-checks.tf.
# The whole feature is gated behind enable_dns_failover so the rest of the
# stack can be applied (or `terraform plan`-ed) without supplying DNS inputs.

variable "enable_dns_failover" {
  description = "Master switch for the Route 53 failover stack (records, health checks, alarms)"
  type        = bool
  default     = false
}

variable "hosted_zone_id" {
  description = "ID of the EXISTING Route 53 hosted zone that owns the failover record (e.g. Z0123456789ABCDEFGHIJ). Required when enable_dns_failover = true."
  type        = string
  default     = ""

  validation {
    condition     = var.hosted_zone_id == "" || can(regex("^Z[A-Z0-9]+$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route 53 zone ID like Z0123456789ABCDEFGHIJ, or empty."
  }
}

variable "failover_record_name" {
  description = "Fully qualified record name to fail over, e.g. app.example.com. Required when enable_dns_failover = true."
  type        = string
  default     = ""
}

variable "failover_record_type" {
  description = "DNS record type for the failover records (A or AAAA when using alias targets)"
  type        = string
  default     = "A"

  validation {
    condition     = contains(["A", "AAAA"], var.failover_record_type)
    error_message = "failover_record_type must be A or AAAA (alias records support these)."
  }
}

variable "primary_alias" {
  description = "Alias target for the PRIMARY (active) endpoint — typically a regional ALB, NLB, CloudFront, or API Gateway. Provide its dns_name and the AWS-published hosted zone ID for that endpoint type."
  type = object({
    dns_name = string
    zone_id  = string
  })
  default = {
    dns_name = ""
    zone_id  = ""
  }
}

variable "secondary_alias" {
  description = "Alias target for the SECONDARY (DR) endpoint in the DR region."
  type = object({
    dns_name = string
    zone_id  = string
  })
  default = {
    dns_name = ""
    zone_id  = ""
  }
}

# ---- Health-check probe configuration ----

variable "primary_health_check_fqdn" {
  description = "Public FQDN the Route 53 health checkers probe for the PRIMARY endpoint (e.g. the primary regional hostname). Required when enable_dns_failover = true."
  type        = string
  default     = ""
}

variable "secondary_health_check_fqdn" {
  description = "Public FQDN the Route 53 health checkers probe for the SECONDARY/DR endpoint. Leave empty to skip monitoring the DR endpoint."
  type        = string
  default     = ""
}

variable "health_check_type" {
  description = "Route 53 health check protocol"
  type        = string
  default     = "HTTPS"

  validation {
    condition     = contains(["HTTP", "HTTPS", "HTTP_STR_MATCH", "HTTPS_STR_MATCH", "TCP"], var.health_check_type)
    error_message = "health_check_type must be one of HTTP, HTTPS, HTTP_STR_MATCH, HTTPS_STR_MATCH, TCP."
  }
}

variable "health_check_port" {
  description = "Port the health checkers connect to"
  type        = number
  default     = 443

  validation {
    condition     = var.health_check_port >= 1 && var.health_check_port <= 65535
    error_message = "health_check_port must be between 1 and 65535."
  }
}

variable "health_check_path" {
  description = "Resource path probed for HTTP(S) health checks (ignored for TCP)"
  type        = string
  default     = "/health"
}

variable "health_check_search_string" {
  description = "String the response body must contain for *_STR_MATCH health-check types (max 255 chars). Ignored for other types."
  type        = string
  default     = ""
}

variable "health_check_failure_threshold" {
  description = "Consecutive failed probes before a health check flips to Unhealthy"
  type        = number
  default     = 3

  validation {
    condition     = var.health_check_failure_threshold >= 1 && var.health_check_failure_threshold <= 10
    error_message = "health_check_failure_threshold must be between 1 and 10."
  }
}

variable "health_check_request_interval" {
  description = "Seconds between Route 53 health-check probes (10 = fast/extra cost, 30 = standard)"
  type        = number
  default     = 30

  validation {
    condition     = contains([10, 30], var.health_check_request_interval)
    error_message = "health_check_request_interval must be 10 or 30 (the only values Route 53 accepts)."
  }
}

variable "health_check_regions" {
  description = "Route 53 checker regions used to evaluate endpoint health (minimum 3)"
  type        = list(string)
  default     = ["us-east-1", "us-west-2", "eu-west-1"]

  validation {
    condition     = length(var.health_check_regions) >= 3
    error_message = "Route 53 requires at least 3 health-check regions."
  }
}

variable "health_check_alarm_failover_email" {
  description = "Email address subscribed to the us-east-1 DNS-failover alarm topic (leave empty to skip subscription)"
  type        = string
  default     = ""
}

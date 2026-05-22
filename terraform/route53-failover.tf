# =============================================================================
# Route 53 DNS Failover — Primary / Secondary records
# =============================================================================
# Implements active-passive DNS failover for the application endpoint. The
# PRIMARY alias points at the active-region endpoint and carries an associated
# Route 53 health check (defined in health-checks.tf). When that health check
# flips to Unhealthy, Route 53 stops answering with the primary record and
# serves the SECONDARY (DR-region) alias instead — no manual DNS edit needed.
#
# Why alias records (not CNAME):
#   * Alias records resolve to the target's IPs at the zone apex AND subdomains.
#   * They are free to query and support evaluate_target_health.
#   * They work for ALB / NLB / CloudFront / API Gateway / S3 website endpoints.
#
# evaluate_target_health is layered ON TOP of the explicit health check:
#   * The explicit health check probes an application path (e.g. /health) and
#     is what the CloudWatch alarms in health-checks.tf watch.
#   * evaluate_target_health lets Route 53 also react to the target's own
#     (e.g. ALB target-group) health, giving defence in depth.
# =============================================================================

locals {
  # Single source of truth for whether the failover stack is materialised.
  dns_failover_enabled = var.enable_dns_failover

  # Only monitor the DR endpoint if a probe FQDN was supplied.
  secondary_health_check_enabled = var.enable_dns_failover && var.secondary_health_check_fqdn != ""
}

# Defensive input validation: when the feature is on, the required inputs must
# actually be present. check{} blocks surface a clear message at plan time
# instead of a confusing apply-time API error.
check "dns_failover_inputs" {
  assert {
    condition = !var.enable_dns_failover || (
      var.hosted_zone_id != "" &&
      var.failover_record_name != "" &&
      var.primary_alias.dns_name != "" &&
      var.secondary_alias.dns_name != "" &&
      var.primary_health_check_fqdn != ""
    )
    error_message = <<-EOT
      enable_dns_failover = true requires: hosted_zone_id, failover_record_name,
      primary_alias.{dns_name,zone_id}, secondary_alias.{dns_name,zone_id}, and
      primary_health_check_fqdn to all be set.
    EOT
  }
}

# ---------------------------------------------------------------------------
# PRIMARY failover record (active region)
# ---------------------------------------------------------------------------
resource "aws_route53_record" "primary" {
  count = local.dns_failover_enabled ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.failover_record_name
  type    = var.failover_record_type

  # set_identifier must be unique among records that share name+type.
  set_identifier = "${local.name_prefix}-primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  # The health check gates whether this record is answered at all.
  health_check_id = aws_route53_health_check.primary[0].id

  alias {
    name                   = var.primary_alias.dns_name
    zone_id                = var.primary_alias.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# SECONDARY failover record (DR region)
# ---------------------------------------------------------------------------
# Route 53 serves this only when the PRIMARY record is unhealthy. We attach a
# health check to the secondary too (when configured) so a DR-region outage is
# visible and so Route 53 can return SERVFAIL rather than black-holing traffic
# to a dead DR endpoint.
resource "aws_route53_record" "secondary" {
  count = local.dns_failover_enabled ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = var.failover_record_name
  type    = var.failover_record_type

  set_identifier = "${local.name_prefix}-secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  health_check_id = local.secondary_health_check_enabled ? aws_route53_health_check.secondary[0].id : null

  alias {
    name                   = var.secondary_alias.dns_name
    zone_id                = var.secondary_alias.zone_id
    evaluate_target_health = true
  }
}

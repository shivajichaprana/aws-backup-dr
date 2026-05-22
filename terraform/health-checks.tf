# =============================================================================
# Route 53 Health Checks + CloudWatch Alarms
# =============================================================================
# Defines the endpoint health checks that drive DNS failover, plus the
# CloudWatch alarms that surface health-check state to operators.
#
# IMPORTANT — region pinning:
#   Route 53 health-check metrics are published to the AWS/Route53 namespace
#   ONLY in us-east-1, no matter where the monitored endpoint lives. Every
#   alarm that watches a HealthCheckId — and the SNS topic those alarms publish
#   to — therefore uses the aws.us_east_1 provider alias (see versions.tf).
#   This is the single most common Route 53 alarm pitfall, so it is handled
#   explicitly here rather than relying on primary_region happening to be
#   us-east-1.
# =============================================================================

locals {
  # search_string is only valid for *_STR_MATCH check types.
  is_str_match_check  = can(regex("_STR_MATCH$", var.health_check_type))
  effective_search    = local.is_str_match_check && var.health_check_search_string != "" ? var.health_check_search_string : null

  # TCP checks cannot probe a resource path.
  is_tcp_check        = var.health_check_type == "TCP"
  effective_path      = local.is_tcp_check ? null : var.health_check_path
}

# ---------------------------------------------------------------------------
# PRIMARY endpoint health check
# ---------------------------------------------------------------------------
resource "aws_route53_health_check" "primary" {
  count = local.dns_failover_enabled ? 1 : 0

  fqdn              = var.primary_health_check_fqdn
  port              = var.health_check_port
  type              = var.health_check_type
  resource_path     = local.effective_path
  search_string     = local.effective_search
  failure_threshold = var.health_check_failure_threshold
  request_interval  = var.health_check_request_interval

  # Probe from multiple regions so a single checker's network blip cannot
  # trigger a false failover; measure_latency surfaces RTT in CloudWatch.
  regions         = var.health_check_regions
  measure_latency = true

  # SNI is required for HTTPS checks against virtual-hosted endpoints.
  enable_sni = can(regex("^HTTPS", var.health_check_type))

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-primary-health"
    Role = "failover-primary"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# SECONDARY (DR) endpoint health check — optional
# ---------------------------------------------------------------------------
resource "aws_route53_health_check" "secondary" {
  count = local.secondary_health_check_enabled ? 1 : 0

  fqdn              = var.secondary_health_check_fqdn
  port              = var.health_check_port
  type              = var.health_check_type
  resource_path     = local.effective_path
  search_string     = local.effective_search
  failure_threshold = var.health_check_failure_threshold
  request_interval  = var.health_check_request_interval

  regions         = var.health_check_regions
  measure_latency = true
  enable_sni      = can(regex("^HTTPS", var.health_check_type))

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-secondary-health"
    Role = "failover-secondary"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Dedicated SNS topic for DNS-failover alarms (us-east-1)
# ---------------------------------------------------------------------------
# Kept separate from the primary-region backup_notifications topic because
# Route 53 alarms can only live in us-east-1 and CloudWatch alarms can only
# publish to a topic in their own region.
resource "aws_sns_topic" "dns_failover_alerts" {
  count    = local.dns_failover_enabled ? 1 : 0
  provider = aws.us_east_1

  name = "${local.name_prefix}-dns-failover-alerts"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-dns-failover-alerts"
    Role = "route53-health-monitoring"
  })
}

resource "aws_sns_topic_subscription" "dns_failover_email" {
  count    = local.dns_failover_enabled && var.health_check_alarm_failover_email != "" ? 1 : 0
  provider = aws.us_east_1

  topic_arn = aws_sns_topic.dns_failover_alerts[0].arn
  protocol  = "email"
  endpoint  = var.health_check_alarm_failover_email
}

# ---------------------------------------------------------------------------
# CloudWatch alarm — PRIMARY endpoint unhealthy (triggers failover)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "primary_unhealthy" {
  count    = local.dns_failover_enabled ? 1 : 0
  provider = aws.us_east_1

  alarm_name        = "${local.name_prefix}-primary-endpoint-unhealthy"
  alarm_description = "PRIMARY endpoint health check is failing — Route 53 is failing over to the DR region. See runbooks/dr-failover.md."

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  dimensions = {
    HealthCheckId = aws_route53_health_check.primary[0].id
  }

  # HealthCheckStatus is 1 (healthy) / 0 (unhealthy). Alarm when the minimum
  # over the period drops below 1, i.e. the check reported unhealthy.
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1

  # Missing data on a Route 53 health check is itself a danger signal.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.dns_failover_alerts[0].arn]
  ok_actions    = [aws_sns_topic.dns_failover_alerts[0].arn]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-primary-endpoint-unhealthy"
  })
}

# ---------------------------------------------------------------------------
# CloudWatch alarm — SECONDARY (DR) endpoint unhealthy
# ---------------------------------------------------------------------------
# If the DR endpoint is also down we have NO healthy target — page loudly.
resource "aws_cloudwatch_metric_alarm" "secondary_unhealthy" {
  count    = local.secondary_health_check_enabled ? 1 : 0
  provider = aws.us_east_1

  alarm_name        = "${local.name_prefix}-dr-endpoint-unhealthy"
  alarm_description = "DR endpoint health check is failing. If PRIMARY also fails there is no healthy target. See runbooks/dr-failover.md."

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  dimensions = {
    HealthCheckId = aws_route53_health_check.secondary[0].id
  }

  comparison_operator = "LessThanThreshold"
  threshold           = 1
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.dns_failover_alerts[0].arn]
  ok_actions    = [aws_sns_topic.dns_failover_alerts[0].arn]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-dr-endpoint-unhealthy"
  })
}

# ---------------------------------------------------------------------------
# CloudWatch alarm — elevated PRIMARY latency (early-warning, non-paging)
# ---------------------------------------------------------------------------
# measure_latency = true publishes ConnectionTime; a sustained climb often
# precedes an outright failure, giving operators a heads-up before failover.
resource "aws_cloudwatch_metric_alarm" "primary_high_latency" {
  count    = local.dns_failover_enabled ? 1 : 0
  provider = aws.us_east_1

  alarm_name        = "${local.name_prefix}-primary-endpoint-high-latency"
  alarm_description = "PRIMARY endpoint connection time is elevated. Early warning — investigate before a hard failover occurs."

  namespace   = "AWS/Route53"
  metric_name = "ConnectionTime"
  dimensions = {
    HealthCheckId = aws_route53_health_check.primary[0].id
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 2000 # milliseconds
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.dns_failover_alerts[0].arn]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-primary-endpoint-high-latency"
  })
}

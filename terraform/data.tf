# Current AWS account identity
data "aws_caller_identity" "current" {}

# Current AWS region (primary)
data "aws_region" "current" {}

# AWS partition (e.g. aws, aws-cn, aws-us-gov)
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  # Resource name prefix
  name_prefix = "${var.project_name}-${var.environment}"

  # Common tags merged with user-supplied tags
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

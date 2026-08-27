terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }

    # `data "archive_file"` packages the reporter and restore-tester Lambdas in
    # reporter.tf and restore-tester.tf. Undeclared, it floated to whatever
    # version `terraform init` happened to resolve.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Configure backend for your environment:
  # backend "s3" {
  #   bucket         = "<your-tfstate-bucket-name>"
  #   key            = "aws-backup-dr/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "<your-lock-table>"
  # }
}

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      Project     = "aws-backup-dr"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

# Secondary provider for the DR region
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = "aws-backup-dr"
      ManagedBy   = "terraform"
      Environment = var.environment
      Role        = "dr-region"
    }
  }
}

# us-east-1 provider alias.
# Route 53 health-check CloudWatch metrics (AWS/Route53 namespace) are ONLY
# published in us-east-1, regardless of where the application runs. Any alarm
# that watches a health check — and the SNS topic that alarm publishes to —
# must therefore live in us-east-1. This alias gives the failover module a
# stable us-east-1 endpoint even when primary_region is something else.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "aws-backup-dr"
      ManagedBy   = "terraform"
      Environment = var.environment
      Role        = "route53-health-monitoring"
    }
  }
}

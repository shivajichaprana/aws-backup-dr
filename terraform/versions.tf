terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
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

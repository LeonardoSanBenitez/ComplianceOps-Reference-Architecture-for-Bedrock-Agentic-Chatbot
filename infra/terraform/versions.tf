terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.27.0"  # S3 Vectors support for Bedrock KB added in v6.27.0
    }
  }

  # State backend: S3 + DynamoDB locking.
  # Bootstrap: bucket and table were created manually (2026-04-23) before
  # Terraform could manage itself. See infra/ci notes for details.
  backend "s3" {
    bucket         = "compliance-ops-bedrock-tfstate"
    key            = "bedrock/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "compliance-ops-bedrock-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "compliance-ops-bedrock"
      ManagedBy   = "zoo"
      Environment = var.environment
    }
  }
}

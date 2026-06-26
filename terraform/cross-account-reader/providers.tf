terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# This stack runs in the *target* account (the one whose pipelines you want
# on the dashboard). Apply it with AWS_PROFILE pointed at that account.
provider "aws" {
  region = var.region
}

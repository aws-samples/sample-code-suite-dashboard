terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.0" }
    awscc   = { source = "hashicorp/awscc", version = ">= 1.0" }
    time    = { source = "hashicorp/time", version = ">= 0.9" }
    random  = { source = "hashicorp/random", version = ">= 3.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# Cloud Control API provider — used exclusively for the DevOps Agent
# resources (awscc_devopsagent_*), which the classic aws provider does not
# expose yet. The two providers coexist safely: everything else in this
# stack stays on the aws provider.
provider "awscc" {
  region = var.aws_region
}

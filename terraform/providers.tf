terraform {
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "4.48"
        }
        confluent = {
            source = "confluentinc/confluent"
            version = "1.23.0"
        }
    }
}
provider "aws" {
    region = local.aws_region
    default_tags {
        tags = {
            owner_email = "${local.owner_email}"
        }
    }
}
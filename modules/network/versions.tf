terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.24.0 added Regional NAT Gateway (availability_mode = "regional").
      version = ">= 6.24"
    }
  }
}

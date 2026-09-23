terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Write-only arguments (password_wo, secret_string_wo).
      version = ">= 6.0"
    }
    random = {
      source = "hashicorp/random"
      # Ephemeral random_password.
      version = ">= 3.7"
    }
  }
}

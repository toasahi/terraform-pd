provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      system      = "alert-pipeline"
      environment = "management"
      component   = "alert-pipeline"
      managed-by  = "terraform"
      repository  = "toasahi/terraform-pd"
    }
  }
}

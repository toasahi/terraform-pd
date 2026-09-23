terraform {
  backend "s3" {
    key = "management/ap-northeast-1/alert-pipeline.tfstate"
  }
}

# Shared S3 backend settings for every root module in this account/region.
#   terraform init -backend-config=../backend.hcl
# The bucket is created by ./bootstrap. S3 native locking (use_lockfile) replaces the deprecated
# DynamoDB lock table (Terraform >= 1.11).
bucket       = "111111111111-tfstate-apne1"
region       = "ap-northeast-1"
encrypt      = true
use_lockfile = true

# Replace the placeholder values before the first apply.
account_id     = "111111111111"
region         = "ap-northeast-1"
name           = "alert-platform"
vpc_cidr_block = "10.40.0.0/20"

private_subnets = {
  "ap-northeast-1a" = "10.40.0.0/22"
  "ap-northeast-1c" = "10.40.4.0/22"
  "ap-northeast-1d" = "10.40.8.0/22"
}

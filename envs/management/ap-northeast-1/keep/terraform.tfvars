# Replace the placeholder values before the first apply.
account_id        = "111111111111"
region            = "ap-northeast-1"
state_bucket_name = "111111111111-tfstate-apne1"
public_zone_name  = "mgmt.example.com"
operator_cidrs    = ["10.255.0.0/16"]

# Set from the output of helpers/mirror-keep-images.sh.
keep_api_image_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
keep_ui_image_digest  = "sha256:0000000000000000000000000000000000000000000000000000000000000000"

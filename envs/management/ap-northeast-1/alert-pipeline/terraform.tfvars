# Replace the placeholder values before the first apply.
account_id        = "111111111111"
region            = "ap-northeast-1"
state_bucket_name = "111111111111-tfstate-apne1"
public_zone_name  = "mgmt.example.com"

# Only the prod and management EKS clusters send alerts. egress_cidrs = NAT egress IPs of each
# cluster's VPC (use fixed EIPs on the sender side; Regional NAT in auto mode may add addresses).
alert_sources = {
  prod = {
    egress_cidrs = ["198.51.100.10/32", "198.51.100.11/32", "198.51.100.12/32"]
  }
  management = {
    egress_cidrs = ["203.0.113.10/32", "203.0.113.11/32", "203.0.113.12/32"]
  }
}

alarm_email_endpoints    = ["sre-oncall@example.com"]
critical_email_endpoints = ["sre-oncall@example.com"]

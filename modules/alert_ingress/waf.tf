# WAF web ACL on the REST API stage. Default action is BLOCK; only the allow-listed source IPs are
# admitted. Every block is a 403 that Alertmanager does not retry, so rules that could produce false
# positives (managed rule groups, rate limit) run in COUNT mode unless explicitly switched to block.
# Note: AWSManagedRulesCommonRuleSet's SizeRestrictions_BODY (8 KB) would block ordinary grouped
# Alertmanager payloads; it is always overridden to COUNT.

resource "aws_wafv2_ip_set" "allowed_sources" {
  name               = "${var.name}-allowed-sources"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.allowed_source_cidrs
}

locals {
  managed_rule_groups = {
    AWSManagedRulesAmazonIpReputationList = { priority = 10, count_rules = [] }
    AWSManagedRulesKnownBadInputsRuleSet  = { priority = 20, count_rules = [] }
    AWSManagedRulesCommonRuleSet          = { priority = 30, count_rules = ["SizeRestrictions_BODY"] }
  }
}

resource "aws_wafv2_web_acl" "main" {
  name  = var.name
  scope = "REGIONAL"

  default_action {
    block {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 0

    action {
      dynamic "block" {
        for_each = var.enable_waf_rate_limit_block ? [1] : []
        content {}
      }

      dynamic "count" {
        for_each = var.enable_waf_rate_limit_block ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5_minutes
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups

    content {
      name     = rule.key
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = var.enable_waf_managed_rules_block ? [1] : []
          content {}
        }

        dynamic "count" {
          for_each = var.enable_waf_managed_rules_block ? [] : [1]
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"

          dynamic "rule_action_override" {
            for_each = rule.value.count_rules

            content {
              name = rule_action_override.value

              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "allow-listed-sources"
    priority = 100

    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.allowed_sources.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-allow-listed-sources"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = aws_api_gateway_stage.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# WAF requires the log group name to start with "aws-waf-logs-".
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}

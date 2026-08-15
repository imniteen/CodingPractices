// TEMPLATE — public internet-facing ALB + WAF. Skeleton, not drop-in: review a plan before applying.
//
// This is the part that has no equivalent in an internal-only deployment, so it is the part most
// likely to be written from memory and got wrong. Everything here is a deliberate choice; the
// comments say why.

// ---------------------------------------------------------------------------------------------
// ALB — the only resource in a public subnet
// ---------------------------------------------------------------------------------------------

resource "aws_lb" "public" {
  name               = "${local.name_prefix}-pub"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]

  // PUBLIC subnets, 2+ AZs. AWS wants >=8 free addresses per subnet for scaling events — see
  // references/discovery.md. Tasks stay in the private subnets.
  subnets = var.public_subnet_ids

  // A public entry point should not be one `terraform destroy` away from gone.
  enable_deletion_protection = true

  // Strips malformed headers rather than passing them to the app. Off by default; no reason to leave it.
  drop_invalid_header_fields = true

  enable_http2 = true
  idle_timeout = 60

  // Enable from day one. After an incident is too late to start collecting them.
  access_logs {
    bucket  = var.alb_access_log_bucket
    prefix  = local.name_prefix
    enabled = true
  }

  tags = { Name = "${local.name_prefix}-pub" }

  // Governance sweepers (Cloud Custodian et al.) tag idle load balancers out of band. Ignoring the
  // SPECIFIC keys they own stops drift on every plan without blinding you to real changes.
  // Narrow this to the keys your org actually uses; a broad ignore hides genuine drift.
  lifecycle {
    ignore_changes = [
      tags["Custodian-System-ELB-Integration"],
      tags_all["Custodian-System-ELB-Integration"],
    ]
  }
}

// ---------------------------------------------------------------------------------------------
// Listeners — 80 exists only to redirect
// ---------------------------------------------------------------------------------------------

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"

  // Do NOT inherit the default policy — it has historically permitted TLS 1.0. Pin it explicitly and
  // verify with `openssl s_client -tls1_1` that the old versions are refused.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = var.acm_certificate_arn // MUST be in this ALB's region

  // Frontend is the catch-all; the api gets an explicit path rule below.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

// Lower priority number wins. Keep the api paths explicit and the frontend as default, so a new
// frontend route never needs a listener change.
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern {
      // Same-origin: one hostname serves both tiers, so the frontend's API base URL builds RELATIVE
      // and one frontend image is valid in every environment. See references/traps.md #13.
      values = ["/api/*", "/healthz", "/readyz"]
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Target groups — 32-char name cap (traps.md #4)
// ---------------------------------------------------------------------------------------------

resource "aws_lb_target_group" "api" {
  // local.tg_prefix is deliberately SHORTER than local.name_prefix. aws_lb_target_group.name caps at
  // 32 characters and the apply fails late, after other resources exist.
  name        = "${local.tg_prefix}-api"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" // required for Fargate awsvpc networking

  health_check {
    // /readyz must assert the schema is at head, or targets go healthy before they can serve
    // (traps.md #14). /healthz is liveness only and is the wrong choice here.
    path                = "/readyz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  // Give in-flight requests time to finish during a rollout. Default 300 s makes deploys drag.
  deregistration_delay = 30

  tags = { Name = "${local.tg_prefix}-api" }
}

resource "aws_lb_target_group" "frontend" {
  name        = "${local.tg_prefix}-fe"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = { Name = "${local.tg_prefix}-fe" }
}

// ---------------------------------------------------------------------------------------------
// WAF — managed rules AND a rate limit. Neither alone is protection.
// ---------------------------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "public" {
  name        = "${local.name_prefix}-acl"
  description = "Edge protection for ${local.name_prefix}"
  scope       = "REGIONAL" // ALB is REGIONAL; CLOUDFRONT scope is only for distributions

  default_action {
    allow {}
  }

  // var.waf_block_mode = false ships every managed rule in COUNT mode. Run it that way first, read the
  // logs, then flip to true. Managed rules false-positive on uploads, rich text and base64-ish payloads
  // — discovering that in block mode means discovering it as a user-visible outage.
  rule {
    name     = "common"
    priority = 10

    override_action {
      dynamic "none" {
        for_each = var.waf_block_mode ? [1] : []
        content {}
      }
      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-common"
      sampled_requests_enabled   = true
    }
  }

  // Repeat the block above for each of: AWSManagedRulesKnownBadInputsRuleSet (priority 20),
  // AWSManagedRulesSQLiRuleSet (30), AWSManagedRulesAmazonIpReputationList (40).
  // Consider AWSManagedRulesBotControlRuleSet only once you know your traffic — it is not free and it
  // is opinionated.

  // Volumetric protection. Managed rules do not do this.
  rule {
    name     = "rate-limit"
    priority = 100

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit // per 5-min window, per IP. Size to REAL traffic.
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-rate"
      sampled_requests_enabled   = true
    }
  }

  // Only when the operator said access is restricted. "Public" rarely means "everyone".
  dynamic "rule" {
    for_each = length(var.allowed_country_codes) > 0 ? [1] : []
    content {
      name     = "geo-restrict"
      priority = 5

      action {
        block {}
      }

      statement {
        not_statement {
          statement {
            geo_match_statement {
              country_codes = var.allowed_country_codes
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name_prefix}-geo"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-acl"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${local.name_prefix}-acl" }
}

// CREATING a web ACL does not attach it. This resource is the one that matters — verify with
// `aws wafv2 get-web-acl-for-resource`.
resource "aws_wafv2_web_acl_association" "public" {
  resource_arn = aws_lb.public.arn
  web_acl_arn  = aws_wafv2_web_acl.public.arn
}

// Without logging, a blocked legitimate request is invisible and you cannot tune the rules.
// NOTE: the log destination name must start with `aws-waf-logs-`.
resource "aws_wafv2_web_acl_logging_configuration" "public" {
  resource_arn            = aws_wafv2_web_acl.public.arn
  log_destination_configs = [var.waf_log_destination_arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}

// ---------------------------------------------------------------------------------------------
// DNS — the PUBLIC zone for a public app
// ---------------------------------------------------------------------------------------------

// If a public AND private zone exist for the same name (split-horizon is common), a record in the
// wrong one resolves internally and nowhere else. Confirm which zone id you were handed.
resource "aws_route53_record" "app" {
  zone_id = var.public_hosted_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = aws_lb.public.dns_name
    zone_id                = aws_lb.public.zone_id
    evaluate_target_health = true
  }
}

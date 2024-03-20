terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
      configuration_aliases = [
        aws.acm_provider,
      ]
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4"
    }
  }
}

locals {
  domain_name = "${var.site_name}.${var.base_domain}"
  origin_path = "/${var.site_name}"
}

# var に依存して定まるリソース名
locals {
  repository_name              = local.domain_name
  veiwer_request_hander_name   = "${var.site_name}_viewer_request"
  codebuild_project_name       = var.site_name
  start_codebuile_policy_name  = "${var.site_name}-start-codebuild"
  push_hook_src_dirname        = "push-hook"
  push_hook_name               = "${var.site_name}-push-hook"
  push_hook_role_name          = "${local.push_hook_name}-role"
  codebuild_log_group_name     = "/aws/codebuild/${var.site_name}"
  codebuild_deploy_policy_name = "deploy-${var.site_name}"
  codebuild_service_role_name  = "codebuild-${var.site_name}-service-role"
}

locals {
  s3_origin_id = "origin"
}

data "aws_region" "current" {}

#
# site distribution
#

resource "aws_acm_certificate" "cert" {
  provider          = aws.acm_provider
  domain_name       = local.domain_name
  key_algorithm     = "EC_prime256v1"
  validation_method = "DNS"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation
resource "aws_acm_certificate_validation" "cert" {
  depends_on      = [cloudflare_record.cert_validation]
  provider        = aws.acm_provider
  certificate_arn = aws_acm_certificate.cert.arn
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_cache_policy
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_response_headers_policy
data "aws_cloudfront_response_headers_policy" "security_headers_policy" {
  name = "Managed-SecurityHeadersPolicy"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_function
resource "aws_cloudfront_function" "veiwer_request_hander" {
  name    = local.veiwer_request_hander_name
  runtime = "cloudfront-js-2.0"
  code = templatefile(
    "${path.module}/cloudfront_function/viewer_request_handler.js.tftpl",
    {
      use_auth : var.require_viewer_auth,
      userpass : base64encode("${var.viewer_auth_user}:${var.viewer_auth_pass}")
    }
  )
}

resource "aws_cloudfront_origin_access_control" "main" {
  name                              = var.site_name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution
resource "aws_cloudfront_distribution" "site" {
  depends_on = [aws_acm_certificate_validation.cert]

  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [local.domain_name]
  default_root_object = "index.html"

  custom_error_response {
    error_caching_min_ttl = 10
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
  }

  origin {
    domain_name              = var.site_bucket.bucket_regional_domain_name
    origin_id                = local.s3_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.main.id
    origin_path              = local.origin_path
  }

  default_cache_behavior {
    target_origin_id = local.s3_origin_id

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    compress = true

    viewer_protocol_policy     = "redirect-to-https"
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers_policy.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.veiwer_request_hander.arn
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  logging_config {
    bucket          = var.log_bucket.bucket_domain_name
    prefix          = "${var.site_name}/"
    include_cookies = true
  }
}

#
# site source
#

resource "aws_codecommit_repository" "site_src" {
  repository_name = local.repository_name
}

resource "aws_codecommit_trigger" "start_codebuild" {
  repository_name = aws_codecommit_repository.site_src.repository_name
  trigger {
    name            = "start-codebuild"
    events          = ["updateReference", "createReference"]
    branches        = ["main"]
    custom_data     = aws_codebuild_project.deploy.name
    destination_arn = aws_lambda_function.push_hook.arn
  }
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name = local.codebuild_log_group_name
}

data "aws_iam_policy_document" "codebuild_base_policy" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      aws_cloudwatch_log_group.codebuild.arn,
      "${aws_cloudwatch_log_group.codebuild.arn}:*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["codecommit:GitPull"]
    resources = [aws_codecommit_repository.site_src.arn]
  }
}

resource "aws_iam_policy" "codebuild_base_policy" {
  name        = "CodeBuildBasePolicy-${local.codebuild_project_name}-${data.aws_region.current.name}"
  description = "Policy used in trust relationship with CodeBuild" # NOTE: これを変えると再作成になる
  path        = "/service-role/"
  policy      = data.aws_iam_policy_document.codebuild_base_policy.json
}

resource "aws_iam_policy" "codebuild_deploy" {
  name = local.codebuild_deploy_policy_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SyncBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          var.site_bucket.arn,
          "${var.site_bucket.arn}/*",
        ]
      },
      {
        Sid      = "ClearCache"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = [aws_cloudfront_distribution.site.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codebuild_deploy" {
  role       = aws_iam_role.codebuild_service_role.name
  policy_arn = aws_iam_policy.codebuild_deploy.arn
}

resource "aws_iam_role_policy_attachment" "codebuild_base" {
  role       = aws_iam_role.codebuild_service_role.name
  policy_arn = aws_iam_policy.codebuild_base_policy.arn
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role
resource "aws_iam_role" "codebuild_service_role" {
  name = local.codebuild_service_role_name
  path = "/service-role/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_codebuild_project" "deploy" {
  name           = local.codebuild_project_name
  service_role   = aws_iam_role.codebuild_service_role.arn
  source_version = "refs/heads/main"

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    environment_variable {
      name  = "BUCKET"
      value = "${var.site_bucket.id}/${var.site_name}"
      type  = "PLAINTEXT"
    }
    environment_variable {
      name  = "DISTRIBUTION"
      value = aws_cloudfront_distribution.site.id
      type  = "PLAINTEXT"
    }
    privileged_mode             = false
    image_pull_credentials_type = "CODEBUILD"
  }

  source {
    type            = "CODECOMMIT"
    location        = aws_codecommit_repository.site_src.clone_url_http
    git_clone_depth = 1
    git_submodules_config {
      fetch_submodules = false
    }
  }
}

data "archive_file" "push_hook" {
  type                    = "zip"
  source_content_filename = "index.mjs"
  source_content          = templatefile("${path.module}/lambda/${local.push_hook_src_dirname}/index.mjs", {})
  output_path             = "${path.module}/lambda/.target/${local.push_hook_name}.zip"
}

data "aws_iam_policy" "lambda_basic_execution_role" {
  name = "AWSLambdaBasicExecutionRole"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy
resource "aws_iam_policy" "start_codebuild" {
  name = local.start_codebuile_policy_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "codebuild:StartBuild"
        Resource = aws_codebuild_project.deploy.arn
      }
    ]
  })
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
resource "aws_iam_role_policy_attachment" "push_hook_start_codebuild" {
  role       = aws_iam_role.push_hook_role.name
  policy_arn = aws_iam_policy.start_codebuild.arn
}

resource "aws_iam_role_policy_attachment" "push_hook_basic_execution" {
  role       = aws_iam_role.push_hook_role.name
  policy_arn = data.aws_iam_policy.lambda_basic_execution_role.arn
}

resource "aws_iam_role" "push_hook_role" {
  name = local.push_hook_role_name
  path = "/service-role/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission
resource "aws_lambda_permission" "codecommit_trigger" {
  function_name = aws_lambda_function.push_hook.arn
  statement_id  = "1"
  action        = "lambda:InvokeFunction"
  principal     = "codecommit.amazonaws.com"
  source_arn    = aws_codecommit_repository.site_src.arn
}

resource "aws_lambda_function" "push_hook" {
  filename         = data.archive_file.push_hook.output_path
  function_name    = local.push_hook_name
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  role             = aws_iam_role.push_hook_role.arn
  publish          = true
  source_code_hash = data.archive_file.push_hook.output_base64sha256
}

#
# DNS
#

data "cloudflare_zone" "base_domain" {
  account_id = var.cloudflare_account_id
  name       = var.base_domain
}

# https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/record
resource "cloudflare_record" "site" {
  zone_id = data.cloudflare_zone.base_domain.id
  name    = var.site_name
  value   = aws_cloudfront_distribution.site.domain_name
  type    = "CNAME"
  proxied = false
}

resource "cloudflare_record" "cert_validation" {
  # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate#referencing-domain_validation_options-with-for_each-based-resources
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.cloudflare_zone.base_domain.id
  name    = trimsuffix(each.value.name, ".${var.base_domain}.")
  value   = each.value.record
  type    = each.value.type
  proxied = false
}

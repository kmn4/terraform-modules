data "aws_canonical_user_id" "current" {}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/cloudfront_log_delivery_canonical_user_id
data "aws_cloudfront_log_delivery_canonical_user_id" "current_region" {}

data "aws_caller_identity" "current" {}

#
# notification
#

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic
resource "aws_sns_topic" "codebuild" {
  name = "codebuild-notifications"
}

resource "aws_sns_topic_policy" "codebuild" {
  arn    = aws_sns_topic.codebuild.arn
  policy = data.aws_iam_policy_document.codebuild_sns_access_policy.json
}

data "aws_iam_policy_document" "codebuild_sns_access_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.codebuild.arn]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_lambda_function.build_hook.arn]
    }
  }
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription
resource "aws_sns_topic_subscription" "codebuild" {
  topic_arn = aws_sns_topic.codebuild.arn
  protocol  = "email"
  endpoint  = var.sns_email_address
}

locals {
  build_hook_name = "site_codebuild_hook"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule
resource "aws_cloudwatch_event_rule" "build_hook" {
  name           = "site-codebuild-hook"
  event_bus_name = "default"
  event_pattern = jsonencode({
    source      = ["aws.codebuild"]
    detail-type = ["CodeBuild Build State Change"]
  })
}

resource "aws_cloudwatch_event_target" "build_hook_lambda" {
  rule      = aws_cloudwatch_event_rule.build_hook.name
  target_id = "SiteBuildHook"
  arn       = aws_lambda_function.build_hook.arn
}

resource "aws_lambda_function" "build_hook" {
  filename         = data.archive_file.build_hook.output_path
  function_name    = local.build_hook_name
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  role             = aws_iam_role.build_hook.arn
  source_code_hash = data.archive_file.build_hook.output_base64sha256
  publish          = true
  environment {
    variables = {
      TARGET_TOPIC_ARN = aws_sns_topic.codebuild.arn
    }
  }
}

data "archive_file" "build_hook" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/build_hook/"
  output_path = "${path.module}/lambda/.target/${local.build_hook_name}.zip"
}

resource "aws_iam_role" "build_hook" {
  name = "site-build-hook"
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

resource "aws_lambda_permission" "build_hook" {
  function_name = aws_lambda_function.build_hook.function_name
  action        = "lambda:InvokeFunction"
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.build_hook.arn
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
resource "aws_iam_role_policy_attachment" "build_hook_notify_sns" {
  role       = aws_iam_role.build_hook.name
  policy_arn = aws_iam_policy.notify_sns.arn
}

resource "aws_iam_role_policy_attachment" "build_hook_basic_execution" {
  role       = aws_iam_role.build_hook.name
  policy_arn = data.aws_iam_policy.lambda_basic_execution_role.arn
}

data "aws_iam_policy" "lambda_basic_execution_role" {
  name = "AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "notify_sns" {
  version = "2012-10-17"
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.codebuild.arn]
  }
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy
resource "aws_iam_policy" "notify_sns" {
  name   = "notify-site-notifications"
  policy = data.aws_iam_policy_document.notify_sns.json
}

#
# buckets
#

resource "aws_s3_bucket" "site" {
  bucket = var.site_bucket_prefix
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket" "log" {
  bucket = var.log_bucket_prefix
}

resource "aws_s3_bucket_ownership_controls" "log" {
  bucket = aws_s3_bucket.log.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

data "aws_iam_policy_document" "cloudfront_fetch" {
  version   = "2008-10-17"
  policy_id = "PolicyForCloudFrontPrivateContent"
  statement {
    sid    = "AllowCloudFrontServicePrincipal"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.site.arn,
      "${aws_s3_bucket.site.arn}/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudfront_fetch" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.cloudfront_fetch.json
}

resource "aws_s3_bucket_acl" "cloudfront_log" {
  depends_on = [aws_s3_bucket_ownership_controls.log]

  bucket = aws_s3_bucket.log.id

  access_control_policy {
    grant {
      grantee {
        id   = data.aws_canonical_user_id.current.id
        type = "CanonicalUser"
      }
      permission = "FULL_CONTROL"
    }

    grant {
      grantee {
        id   = data.aws_cloudfront_log_delivery_canonical_user_id.current_region.id
        type = "CanonicalUser"
      }
      permission = "FULL_CONTROL"
    }

    owner {
      id = data.aws_canonical_user_id.current.id
    }
  }
}

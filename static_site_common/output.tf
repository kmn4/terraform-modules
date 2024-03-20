output "sns_topic_codebuild_arn" {
  value = aws_sns_topic.codebuild.arn
}

output "site_bucket" {
  value = aws_s3_bucket.site
}

output "log_bucket" {
  value = aws_s3_bucket.log
}

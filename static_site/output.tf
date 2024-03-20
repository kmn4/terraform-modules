output "codecommit_url" {
  value = aws_codecommit_repository.site_src.clone_url_http
}

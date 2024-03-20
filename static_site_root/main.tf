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

module "site_common" {
  source = "../static_site_common"

  sns_email_address  = var.email_address
  site_bucket_prefix = var.site_bucket_prefix
  log_bucket_prefix  = var.log_bucket_prefix
}

module "site" {
  for_each = var.site_configs
  source = "../static_site"

  providers = {
    aws.acm_provider = aws.acm_provider
  }

  site_name             = each.key
  base_domain           = var.base_domain
  site_bucket           = module.site_common.site_bucket
  log_bucket            = module.site_common.log_bucket
  cloudflare_account_id = var.cloudflare_account_id
  require_viewer_auth   = each.value["viewer_auth"] != null
  viewer_auth_user      = each.value["viewer_auth"] != null ? each.value["viewer_auth"]["user"] : null
  viewer_auth_pass      = each.value["viewer_auth"] != null ? each.value["viewer_auth"]["pass"] : null
}

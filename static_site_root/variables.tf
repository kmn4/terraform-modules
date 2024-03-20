variable "base_domain" {
  type = string
}

variable "email_address" {
  type = string
}

variable "cloudflare_account_id" {
  type = string
}

variable "site_bucket_prefix" {
  type = string
}

variable "log_bucket_prefix" {
  type = string
}

variable "site_configs" {
  type = map(object({
    viewer_auth = optional(object({
      user = string
      pass = string
    }))
  }))
}

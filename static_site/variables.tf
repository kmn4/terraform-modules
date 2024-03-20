variable "site_name" {
  description = "ホスト名。サイトは <site_name>.<base_domain> に公開される。"
  type        = string
}

variable "base_domain" {
  description = "ドメイン名。サイトは <site_name>.<base_domain> に公開される。"
  type        = string
}

variable "require_viewer_auth" {
  type    = bool
  default = false
}

variable "viewer_auth_user" {
  type     = string
  default  = "user"
  nullable = false
}

variable "viewer_auth_pass" {
  type     = string
  default  = "pass"
  nullable = false
}

variable "site_bucket" {
  type = any
}

variable "log_bucket" {
  type = any
}

variable "cloudflare_account_id" {
  description = "<base_domain> を管理している Cloudflare アカウントの ID"
  type        = string
}

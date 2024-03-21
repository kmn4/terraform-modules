# terraform-modules

以下の「使い方」では、本リポジトリがルートモジュール直下の `modules` ディレクトリにチェックアウトされていることを想定している。

## static_site*

https://blog.kamasaki.net/post/oreore-github-pages-on-aws/

> [!IMPORTANT]
> サイトの DNS ゾーンは Cloudflare で管理されていることを前提としています。

### 使い方

1. AWS リソースと DNS レコードを作成
1. サイトコンテンツを作成しプッシュ

#### AWS リソースと DNS レコードの作成

1. ルートモジュールに以下のような `main.tf` を作る
1. `terraform init` 
1. `terraform plan`
1. `terraform apply`

下の例では 2 つの Web サイトが構築されます。
* `www.example.com`
* `private.example.com`

各サイトごとに対応する CodeCommit リポジトリが作成されます。リポジトリの名前は対応するサイトの FQDN です。

```tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

# CloudFront で使用する ACM 証明書はバージニア北部に作成する必要がある
# https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html#https-requirements-certificate-issuer
provider "aws" {
  alias  = "acm_provider"
  region = "us-east-1"
}

provider "cloudflare" {
  # base_domain (下記) を含む DNS ゾーンの編集権限を持つ Cloudflare API トークン
  api_token = "<your-cloudflare-access-token>"
}

module "site_root" {
  source = "./modules/static_site_root"

  providers = {
    aws.acm_provider = aws.acm_provider
  }

  # Cloudflare で管理しているドメイン名
  base_domain           = "example.com"
  # ビルドの通知先メールアドレス
  email_address         = "foo@example.com"
  # base_domain を含む DNS ゾーンを管理する Cloudflare アカウント ID
  cloudflare_account_id = "<your-cloudflare-account>"
  # Web サイトコンテンツを格納するバケット名のプレフィックス
  site_bucket_prefix    = "example-site-content"
  # CloudFront アクセスログを格納するバケット名のプレフィックス
  log_bucket_prefix     = "example-site-log"
  # サイトごとに固有の設定
  # キーを <key> とするとき、サイトは <key>.<base_domain> に公開される
  site_configs          = {
    # 公開サイト
    "www"     = {}
    # 非公開サイト: viewer_auth.{user,pass} に従って Basic 認証が設定される
    "private" = {
      viewer_auth = {
        user = "user"
        pass = "pass"
      }
    } 
  }
}
```

#### サイトコンテンツを作成しプッシュ

1. CodeCommit 用のクレデンシャルを作成 https://docs.aws.amazon.com/codecommit/latest/userguide/setting-up-gc.html
1. リポジトリを作成し CodeCommit へプッシュ
    - `public/index.html` を作成
    - 以下のような `buildspec.yml` を作成

```yml
version: 0.2

phases:
# Hugo を使う場合、以下のコメントアウトを解除:
#   install:
#     commands:
#       - apt-get install -y hugo
#   build:
#     commands:
#       - hugo --minify
  post_build:
    commands:
      # サイトコンテンツ用バケットへ生成物を配布
      - aws s3 sync --size-only --delete ./public s3://${BUCKET}/
      # CloudFront ディストリビューションのキャッシュを削除
      - aws cloudfront create-invalidation --distribution-id ${DISTRIBUTION} --paths '/*'
```

`BUCKET` と `DISTRIBUTION` は本モジュールが作成するリソースに埋め込まれた環境変数なので、実際の値へと手動で置き換える必要はありません。

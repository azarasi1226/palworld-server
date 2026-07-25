terraform {
  # use_lockfile (S3 ネイティブロック) を使うため 1.10 以上
  required_version = ">= 1.10.0"

  # state には SSM SecureString の値 (webhook URL / パスワード) が平文で入るため
  # 暗号化された S3 に置く。バケット名は環境ごとに変わるので init 時に渡す:
  #   terraform init -backend-config="bucket=<state 用バケット名>"
  # バケットの作成手順は README「4. デプロイする」を参照。
  backend "s3" {
    key          = "palworld/terraform.tfstate"
    region       = "ap-northeast-1" # aws_region を変える場合はここも合わせる
    encrypt      = true
    use_lockfile = true # DynamoDB を使わない S3 ネイティブロック
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

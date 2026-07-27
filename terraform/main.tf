# ---------------------------------------------------------------------------
# 共通のデータソース・生成値・locals。
# 実リソースの定義は用途ごとのファイルに分かれている:
#   network.tf         VPC / サブネット / ルーティング (配管)
#   security_group.tf  外部への公開面 (どのポートが開いているか)
#   asg.tf      起動テンプレート / Auto Scaling Group
#   lambda.tf   Discord Bot / API Gateway / EventBridge
#   s3.tf       セーブ置き場 / サーバースクリプトの配布
#   iam.tf      インスタンスロール / Lambda ロール
#   ssm.tf      秘匿値 (SecureString)
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# 対象リージョンで実際にインスタンスを起動できる AZ のみを対象にする。
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Ubuntu 24.04 LTS (amd64 / gp3) の最新 AMI。Canonical 公式の SSM パブリックパラメータ。
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_route53_zone" "main" {
  name         = "${var.route53_zone_name}."
  private_zone = false
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "random_password" "admin" {
  length  = 24
  special = false # Palworld の ini はクォートを扱えないため英数字に限定する
}

locals {
  name   = var.project_name
  suffix = random_id.suffix.hex

  bucket_name = "${var.project_name}-${data.aws_caller_identity.current.account_id}-${local.suffix}"
  fqdn        = "${var.server_hostname}.${var.route53_zone_name}"

  admin_password = var.admin_password != "" ? var.admin_password : random_password.admin.result

  # 各 AZ に /20 のパブリックサブネットを 1 つずつ (network.tf で使用)。
  # スポットのキャパシティプールは「インスタンスタイプ × AZ」で決まるため、
  # AZ を全部使うことが中断されにくさに直結する。
  azs = slice(data.aws_availability_zones.available.names, 0, min(4, length(data.aws_availability_zones.available.names)))
}

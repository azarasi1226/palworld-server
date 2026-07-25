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

  # 各 AZ に /20 のパブリックサブネットを 1 つずつ。
  # スポットのキャパシティプールは「インスタンスタイプ × AZ」で決まるため、
  # AZ を全部使うことが中断されにくさに直結する。
  azs = slice(data.aws_availability_zones.available.names, 0, min(4, length(data.aws_availability_zones.available.names)))
}

# ---------------------------------------------------------------------------
# ネットワーク
#   NAT ゲートウェイは置かない (月 $40 かかる)。
#   インスタンスはパブリックサブネットに直接置き、パブリック IP を持たせる。
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 4, each.value)
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# セキュリティグループ
#   SSH は開けない。運用・デバッグは SSM Session Manager を使う。
# ---------------------------------------------------------------------------

resource "aws_security_group" "server" {
  name        = "${local.name}-server"
  description = "Palworld dedicated server"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-server" }
}

resource "aws_vpc_security_group_ingress_rule" "game" {
  security_group_id = aws_security_group.server.id
  description       = "Palworld game traffic"
  ip_protocol       = "udp"
  from_port         = var.game_port
  to_port           = var.game_port
  cidr_ipv4         = "0.0.0.0/0"
}

# コミュニティサーバー一覧に載せる場合のみ有効化する。
resource "aws_vpc_security_group_ingress_rule" "query" {
  count = var.enable_steam_query_port ? 1 : 0

  security_group_id = aws_security_group.server.id
  description       = "Steam query"
  ip_protocol       = "udp"
  from_port         = 27015
  to_port           = 27015
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.server.id
  description       = "Steam / S3 / SSM"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

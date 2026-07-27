# ---------------------------------------------------------------------------
# ネットワークの配管 (VPC / サブネット / ルーティング)。
#   NAT ゲートウェイは置かない (月 $40 かかる)。
#   インスタンスはパブリックサブネットに直接置き、パブリック IP を持たせる。
#   外部への公開面 (どのポートが開いているか) は security_group.tf。
# ---------------------------------------------------------------------------

# 対象リージョンで実際にインスタンスを起動できる AZ のみを対象にする。
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # 各 AZ に /20 のパブリックサブネットを 1 つずつ。
  # スポットのキャパシティプールは「インスタンスタイプ × AZ」で決まるため、
  # AZ を全部使うことが中断されにくさに直結する (asg.tf の instance_types と対)。
  azs = slice(data.aws_availability_zones.available.names, 0, min(4, length(data.aws_availability_zones.available.names)))
}

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

# 各 AZ に /20 のパブリックサブネットを 1 つずつ (AZ の一覧は main.tf の locals)。
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

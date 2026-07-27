# ---------------------------------------------------------------------------
# セキュリティグループ = このシステムの外部公開面。
#
# ここに書かれた ingress がインターネットから到達できる唯一の経路。
# 「何が外部に開いているか」を 1 ファイルで確認できるよう、
# 配管 (VPC / サブネット / ルーティング = network.tf) とは分けている。
#
# SSH (22) は開けない。運用・デバッグは SSM Session Manager 経由で行うため、
# 受信ポートを増やさずにシェルへ入れる。
# ---------------------------------------------------------------------------

resource "aws_security_group" "server" {
  name        = "${local.name}-server"
  description = "Palworld dedicated server"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-server" }
}

# --- 受信 -------------------------------------------------------------------

# ゲーム本体の通信。全世界に開ける必要がある (プレイヤーの接続元は不定)。
# 不正アクセス対策は Palworld 側の server_password が担う。
resource "aws_vpc_security_group_ingress_rule" "game" {
  security_group_id = aws_security_group.server.id
  description       = "Palworld game traffic"
  ip_protocol       = "udp"
  from_port         = var.game_port
  to_port           = var.game_port
  cidr_ipv4         = "0.0.0.0/0"
}

# コミュニティサーバー一覧への掲載に使うクエリポート。
# PS5 / Xbox は IP 直接入力ができず一覧経由でしか参加できないため、
# コンソール勢がいる場合は enable_public_lobby とセットで true にする。
# 一覧はサーバー名が全世界に見えるので、掲載時は server_password 必須。
resource "aws_vpc_security_group_ingress_rule" "query" {
  count = var.enable_steam_query_port ? 1 : 0

  security_group_id = aws_security_group.server.id
  description       = "Steam query"
  ip_protocol       = "udp"
  from_port         = 27015
  to_port           = 27015
  cidr_ipv4         = "0.0.0.0/0"
}

# --- 送信 -------------------------------------------------------------------

# Steam からのゲーム本体取得、S3 へのセーブ退避、SSM への接続に必要。
# 送信先を絞ると steamcmd の CDN が追えなくなるため全許可のままとする。
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.server.id
  description       = "Steam / S3 / SSM"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

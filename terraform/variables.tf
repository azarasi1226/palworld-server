variable "aws_region" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "palworld"
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

variable "route53_zone_name" {
  description = "既存の Route53 ホストゾーン名 (末尾ドット無し)。例: example.com"
  type        = string
}

variable "server_hostname" {
  description = "サーバーのホスト名 (ゾーン名を除いた部分)。例: pal -> pal.example.com"
  type        = string
  default     = "pal"
}

# ---------------------------------------------------------------------------
# Discord
# ---------------------------------------------------------------------------

variable "discord_application_id" {
  description = "Discord アプリケーション ID"
  type        = string
}

variable "discord_public_key" {
  description = "Discord アプリの Public Key (署名検証用・16進文字列)"
  type        = string
}

variable "discord_webhook_url" {
  description = "起動完了 / 中断警告などをサーバーから通知する Discord Webhook URL"
  type        = string
  sensitive   = true
}

variable "discord_allowed_role_id" {
  description = "start/stop を許可する Discord ロール ID。空文字なら全員許可"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Palworld サーバー設定
# ---------------------------------------------------------------------------

variable "server_name" {
  description = "サーバー一覧に表示される名前"
  type        = string
  default     = "Palworld Spot Server"
}

variable "server_description" {
  type    = string
  default = "Managed by Discord"
}

variable "server_password" {
  description = "参加パスワード。空文字ならパスワード無し"
  type        = string
  default     = ""
  sensitive   = true
}

variable "admin_password" {
  description = "管理者パスワード (RCON のパスワードも兼ねる)。空なら自動生成"
  type        = string
  default     = ""
  sensitive   = true
}

variable "max_players" {
  type    = number
  default = 16
}

variable "game_port" {
  type    = number
  default = 8211
}

variable "enable_steam_query_port" {
  description = "27015/udp を開放する。コミュニティサーバー一覧に掲載したい場合のみ true"
  type        = bool
  default     = false
}

variable "enable_public_lobby" {
  description = <<-EOT
    コミュニティサーバー一覧に掲載する (-publiclobby)。
    PS5/Xbox 版には IP 直接入力が無く一覧経由でしか参加できないため、
    コンソール勢がいる場合は true 必須。掲載する場合は server_password の設定を強く推奨。
  EOT
  type        = bool
  default     = false
}

variable "crossplay_platforms" {
  description = "参加を許可するプラットフォーム (CrossplayPlatforms)。欠けた環境からは接続不可"
  type        = string
  default     = "Steam,Xbox,PS5,Mac"
}

variable "extra_pal_settings" {
  description = <<-EOT
    PalWorldSettings.ini の OptionSettings に追記する key=value のマップ。
    例: { DeathPenalty = "None", ExpRate = "2.000000" }
  EOT
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# インフラ / コスト
# ---------------------------------------------------------------------------

variable "instance_types" {
  description = <<-EOT
    ASG が選択できるインスタンスタイプ。すべてメモリ 16GB 以上。
    種類を多くするほどスポット中断されにくくなる。
  EOT
  type        = list(string)
  default = [
    "m7i.xlarge",  # 4vCPU / 16GB
    "m7a.xlarge",  # 4vCPU / 16GB
    "m6i.xlarge",  # 4vCPU / 16GB
    "m6a.xlarge",  # 4vCPU / 16GB
    "m5.xlarge",   # 4vCPU / 16GB
    "m5a.xlarge",  # 4vCPU / 16GB
    "c7i.2xlarge", # 8vCPU / 16GB
    "c6i.2xlarge", # 8vCPU / 16GB
    "c5.2xlarge",  # 8vCPU / 16GB
    "r6i.xlarge",  # 4vCPU / 32GB
    "r5.xlarge",   # 4vCPU / 32GB
  ]
}

variable "root_volume_size" {
  description = "ルート EBS サイズ (GB)。ゲーム本体 ~10GB + セーブ + 作業領域"
  type        = number
  default     = 40
}

variable "idle_shutdown_minutes" {
  description = "接続者 0 人がこの分数続いたら自動でセーブして停止する。0 で無効"
  type        = number
  default     = 15
}

variable "backup_interval_minutes" {
  description = "S3 への定期バックアップ間隔 (分)。スポット中断時の最大ロスト時間"
  type        = number
  default     = 5
}

variable "backup_retention_days" {
  description = "世代バックアップの保持日数"
  type        = number
  default     = 30
}

variable "boot_grace_minutes" {
  description = "起動後この分数はアイドル判定を行わない (誰も繋ぐ前に落ちるのを防ぐ)"
  type        = number
  default     = 10
}

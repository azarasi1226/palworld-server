# ---------------------------------------------------------------------------
# 秘匿値は SecureString で持ち、EC2 / Lambda が実行時に読む。
# user_data やログに平文で出さないための置き場。
# ---------------------------------------------------------------------------

resource "random_password" "admin" {
  length  = 24
  special = false # Palworld の ini はクォートを扱えないため英数字に限定する
}

locals {
  # 未指定なら自動生成。outputs.tf から terraform output -raw admin_password で取れる。
  admin_password = var.admin_password != "" ? var.admin_password : random_password.admin.result
}

resource "aws_ssm_parameter" "discord_webhook" {
  name        = "/${local.name}/discord/webhook_url"
  description = "サーバーからの通知先 Discord Webhook"
  type        = "SecureString"
  value       = var.discord_webhook_url
}

resource "aws_ssm_parameter" "admin_password" {
  name        = "/${local.name}/server/admin_password"
  description = "Palworld 管理者パスワード (RCON 兼用)"
  type        = "SecureString"
  value       = local.admin_password
}

resource "aws_ssm_parameter" "server_password" {
  name        = "/${local.name}/server/server_password"
  description = "Palworld 参加パスワード (空文字ならパスワード無し)"
  type        = "SecureString"
  value       = var.server_password != "" ? var.server_password : "__EMPTY__"
}

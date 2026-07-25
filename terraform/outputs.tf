output "interactions_endpoint_url" {
  description = "Discord Developer Portal の Interactions Endpoint URL に登録する URL"
  value       = aws_lambda_function_url.discord.function_url
}

output "server_address" {
  description = "ゲームからの接続先"
  value       = "${local.fqdn}:${var.game_port}"
}

output "s3_bucket" {
  description = "セーブ・キャッシュ・ログの置き場"
  value       = aws_s3_bucket.state.id
}

output "asg_name" {
  description = "手動操作用: aws autoscaling set-desired-capacity --auto-scaling-group-name <この値> --desired-capacity 1"
  value       = aws_autoscaling_group.server.name
}

output "admin_password" {
  description = "自動生成された管理者パスワード (terraform output -raw admin_password で表示)"
  value       = local.admin_password
  sensitive   = true
}

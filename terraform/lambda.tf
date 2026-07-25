# ---------------------------------------------------------------------------
# Discord Bot 本体。
# API Gateway は使わず Function URL に Discord から直接 POST させる。
# 認証は Ed25519 署名検証 (Discord の秘密鍵でしか作れない) が担う。
# ---------------------------------------------------------------------------

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/.terraform/tmp/lambda.zip"
}

resource "aws_lambda_function" "discord" {
  function_name = "${local.name}-discord"
  role          = aws_iam_role.lambda.arn
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  architectures = ["arm64"] # Lambda は Graviton でよい (安い)。x86 縛りはゲームサーバーだけ

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  timeout     = 120 # ワーカー実行 (SSM RunCommand の完了待ち等) を含む
  memory_size = 256

  # URL が公開される以上、無署名リクエストの連打で課金が青天井にならないよう頭打ちにする。
  reserved_concurrent_executions = 5

  environment {
    variables = {
      DISCORD_APP_ID       = var.discord_application_id
      DISCORD_PUBLIC_KEY   = var.discord_public_key
      DISCORD_ROLE_ID      = var.discord_allowed_role_id
      ASG_NAME             = aws_autoscaling_group.server.name
      BUCKET               = aws_s3_bucket.state.id
      WEBHOOK_PARAM        = aws_ssm_parameter.discord_webhook.name
      SERVER_FQDN          = local.fqdn
      GAME_PORT            = tostring(var.game_port)
      SELF_FUNCTION_NAME   = "${local.name}-discord"
      STATUS_STALE_SECONDS = "90"
    }
  }
}

resource "aws_lambda_function_url" "discord" {
  function_name      = aws_lambda_function.discord.function_name
  authorization_type = "NONE" # Discord は SigV4 不可。認証は Ed25519 署名検証で行う
}

# Function URL の公開呼び出し許可。コンソール作成時は自動付与されるが
# Terraform では明示が必要 (無いと全リクエストが 403 になる)。
resource "aws_lambda_permission" "function_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.discord.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# ---------------------------------------------------------------------------
# 通知 B 系統: インスタンスの生死に関係なく届く AWS 側イベント。
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${local.name}-spot-interruption"
  description = "Spot 中断警告を Discord へ通知 (インスタンス側通知が飛ばない場合の保険)"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_rule" "launch_failure" {
  name        = "${local.name}-launch-failure"
  description = "キャパシティ枯渇などで復帰できない状態を通知"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance Launch Unsuccessful"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.server.name]
    }
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_lambda_function.discord.arn
}

resource "aws_cloudwatch_event_target" "launch_failure" {
  rule = aws_cloudwatch_event_rule.launch_failure.name
  arn  = aws_lambda_function.discord.arn
}

resource "aws_lambda_permission" "eventbridge_spot" {
  statement_id  = "AllowSpotInterruptionEvent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.spot_interruption.arn
}

resource "aws_lambda_permission" "eventbridge_launch" {
  statement_id  = "AllowLaunchFailureEvent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.launch_failure.arn
}

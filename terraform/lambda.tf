# ---------------------------------------------------------------------------
# Discord Bot 本体。
# 入口は API Gateway (HTTP API)。当初は Function URL だったが、この組織には
# 「Function URL の匿名呼び出しを禁止する」ガードレール (RCP) があり 403 になるため。
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

  # reserved_concurrent_executions による予約は設定しない。
  # 小規模アカウント (全体上限 10) では「未予約を 10 以上残す」制約に必ず抵触するため。
  # 連打対策はアカウント全体の同時実行上限と Ed25519 署名検証 (即 401) で足りる。

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

# HTTP API (v2)。ペイロード形式 2.0 は Function URL とイベント構造が同一のため、
# Lambda 側のコードは無変更で済む。
resource "aws_apigatewayv2_api" "discord" {
  name          = "${local.name}-discord"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "discord" {
  api_id                 = aws_apigatewayv2_api.discord.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.discord.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "discord" {
  api_id    = aws_apigatewayv2_api.discord.id
  route_key = "POST /"
  target    = "integrations/${aws_apigatewayv2_integration.discord.id}"
}

resource "aws_apigatewayv2_stage" "discord" {
  api_id      = aws_apigatewayv2_api.discord.id
  name        = "$default"
  auto_deploy = true

  # 公開エンドポイントの連打対策。Discord の正規トラフィックは毎秒数回も来ない。
  default_route_settings {
    throttling_rate_limit  = 5
    throttling_burst_limit = 10
  }
}

resource "aws_lambda_permission" "apigateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.discord.execution_arn}/*/*"
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

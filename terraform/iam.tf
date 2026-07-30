# ---------------------------------------------------------------------------
# EC2 インスタンスロール
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM Session Manager (SSH 代替) と RunCommand の受信に必要。
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  # セーブ・キャッシュ・ロック・status の読み書き。バケットはこのプロジェクト専用。
  statement {
    sid = "S3State"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
  }

  statement {
    sid = "ReadSecrets"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      aws_ssm_parameter.discord_webhook.arn,
      aws_ssm_parameter.admin_password.arn,
      aws_ssm_parameter.server_password.arn,
    ]
  }

  # guardian が自分の ASG 状態 (Terminating:Wait) を監視し、
  # graceful-stop が停止原因 (ユーザー停止 or 置き換え) を desired 値で判定する。
  # Describe 系 API はリソースレベル制限が効かない。
  statement {
    sid = "AsgDescribe"
    actions = [
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeAutoScalingGroups",
    ]
    resources = ["*"]
  }

  statement {
    sid = "AsgLifecycle"
    actions = [
      "autoscaling:CompleteLifecycleAction",
      "autoscaling:RecordLifecycleActionHeartbeat",
      "autoscaling:SetDesiredCapacity", # アイドル停止・起動失敗時に自分で 0 にする
    ]
    resources = [aws_autoscaling_group.server.arn]
  }

  # 起動時に自分の Public IP を A レコードへ UPSERT する。
  # 注意: この権限はゾーン単位。ゾーンを他用途と共有している場合は
  # ゲーム専用サブドメインのゾーンに分離すること (DESIGN.md リスク表参照)。
  statement {
    sid       = "Route53Upsert"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [data.aws_route53_zone.main.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["A"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [local.fqdn]
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${local.name}-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# Lambda ロール (Discord Bot)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid = "AsgControl"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:UpdateAutoScalingGroup",
    ]
    resources = [aws_autoscaling_group.server.arn]
  }

  # Describe 系はリソースレベル制限不可。
  # DescribeSpotPriceHistory は /pal cost の「現在の時間単価」算出に使う。
  statement {
    sid = "Describe"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeSpotPriceHistory",
    ]
    resources = ["*"]
  }

  # /pal status /pal players 用に status.json を読む。
  statement {
    sid       = "ReadStatus"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/status.json"]
  }

  # /pal cost: Cost Explorer は 1 リクエスト $0.01 の有料 API のため、
  # 結果を S3 に 1 時間キャッシュして連打しても課金が増えないようにする。
  statement {
    sid       = "CostExplorer"
    actions   = ["ce:GetCostAndUsage"]
    resources = ["*"] # CE はリソースレベル制限に非対応
  }

  statement {
    sid       = "CostCache"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/cost-cache.json"]
  }

  # /pal backup: インスタンス上で即時バックアップを実行する。
  # SendCommand はドキュメント側とターゲット側の両方の許可が要る。
  statement {
    sid       = "RunCommandDoc"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "RunCommandTarget"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid       = "RunCommandResult"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  # deferred 応答のためワーカーとして自分自身を非同期 invoke する。
  # 自己参照になるため関数名を直接組み立てる。
  statement {
    sid       = "SelfInvoke"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.name}-discord"]
  }

  # EventBridge 経由の通知で webhook URL を読む。
  statement {
    sid       = "ReadWebhook"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.discord_webhook.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.name}-lambda"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

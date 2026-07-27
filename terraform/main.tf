# ---------------------------------------------------------------------------
# 複数ファイルから参照される共通の値だけを置く。
# 1 ファイルでしか使わないデータソースや locals は、使う側のファイルで定義する。
#
#   network.tf         VPC / サブネット / ルーティング (配管)
#   security_group.tf  外部への公開面 (どのポートが開いているか)
#   asg.tf             起動テンプレート / Auto Scaling Group
#   lambda.tf          Discord Bot / API Gateway / EventBridge
#   s3.tf              セーブ置き場 / サーバースクリプトの配布
#   iam.tf             インスタンスロール / Lambda ロール
#   ssm.tf             秘匿値 (SecureString)
# ---------------------------------------------------------------------------

# s3.tf (バケット名) と iam.tf (ARN 組み立て) が参照する。
data "aws_caller_identity" "current" {}

# asg.tf (レコード更新先) と iam.tf (権限のスコープ) が参照する。
data "aws_route53_zone" "main" {
  name         = "${var.route53_zone_name}."
  private_zone = false
}

locals {
  # ほぼ全リソースの名前プレフィックス。
  name = var.project_name

  # プレイヤーの接続先。asg.tf / iam.tf / lambda.tf / outputs.tf が参照する。
  fqdn = "${var.server_hostname}.${var.route53_zone_name}"
}

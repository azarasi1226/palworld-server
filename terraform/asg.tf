# ---------------------------------------------------------------------------
# 起動テンプレート + AutoScalingGroup
#   Discord の start/stop は desired capacity の 0<->1 切替として実装される。
# ---------------------------------------------------------------------------

# Ubuntu 24.04 LTS (amd64 / gp3) の最新 AMI。Canonical 公式の SSM パブリックパラメータ。
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# 起動テンプレート = 「インスタンスをどう作るか」のレシピ。
resource "aws_launch_template" "server" {
  name = "${local.name}-server"

  # AMI ID を直書きしないので、作り直すたびに最新の Ubuntu が使われる。
  image_id = data.aws_ssm_parameter.ubuntu_ami.value

  # EBS最適化オプションは、EC2インスタンスのEBSのI/O性能を最適化するオプションです。
  # こちらを有効にすると、EBSボリュームへの読み書きが他のトラフィックと分離されて専用の帯域幅を持ち、EBSボリュームの性能が向上します。
  ebs_optimized = true

  # インスタンスに渡す権限。EC2 にはロールを直接付けられず、
  # インスタンスプロファイルという包み紙を必ず経由する (歴史的経緯による仕様)。
  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [aws_security_group.server.id]

  block_device_mappings {
    # Ubuntu の公式 AMI はルートボリュームをこの名前で持つ。
    # ここを間違えると「追加ディスク」が生えるだけでルートは拡張されない。
    device_name = "/dev/sda1"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      delete_on_termination = true # インスタンスは使い捨て。状態は S3 が持つ
      encrypted             = true
    }
  }

  metadata_options {
    # IMDSv2 必須。v1 はトークン不要で、サーバー上の SSRF 等から
    # インスタンスの一時認証情報を抜かれる経路になりうるため塞ぐ。
    http_tokens = "required"

    # メタデータに到達できるネットワークホップ数。1 = インスタンス本体のみ。
    # (コンテナ内から叩く構成なら 2 が必要。ここは素のホストで動かすため 1 で足りる)
    # guardian がスポット中断通知を取りに行くのもこの経路。
    http_put_response_hop_limit = 1

    instance_metadata_tags = "disabled"
  }

  # user_data は S3 からスクリプト一式を取って install.sh に委譲する薄いラッパー。
  # 本体のロジックを S3 側に置くことで、修正が AMI 再作成なしに次回起動から反映される。
  #
  # templatefile() が第 2 引数の値を .tftpl 内の ${...} に埋め込み、
  # base64encode() で EC2 が要求する形式に変換する。
  # ここで渡した値は起動時に /etc/palworld/env として書き出され、
  # サーバー側の全スクリプトが common.sh 経由で参照する。
  #
  # 注意: ここを変えても、既に動いているインスタンスには反映されない。
  # 次回起動 (= /pal restart) で初めて効く。
  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    bucket        = aws_s3_bucket.state.id
    region        = var.aws_region
    project       = local.name
    fqdn          = local.fqdn
    zone_id       = data.aws_route53_zone.main.zone_id
    game_port     = var.game_port
    server_name   = var.server_name
    server_desc   = var.server_description
    max_players   = var.max_players
    idle_minutes  = var.idle_shutdown_minutes
    backup_min    = var.backup_interval_minutes
    grace_minutes = var.boot_grace_minutes
    public_lobby  = var.enable_public_lobby ? "true" : "false"
    crossplay     = var.crossplay_platforms
    # map を "キー=値,キー=値" の 1 行にまとめて渡す。
    # サーバー側 (install.sh) がこれを分解して ini に注入する。
    # そのため値そのものにカンマは使えない。
    extra_settings = join(",", [
      for k, v in var.extra_pal_settings : "${k}=${v}"
    ])
  }))

  # tag_specifications は「起動テンプレートが作るリソースに付けるタグ」。
  # provider の default_tags はテンプレート自身にしか効かず、
  # ここから生えるインスタンスや EBS には伝播しないため個別に指定する。
  tag_specifications {
    resource_type = "instance"

    tags = {
      Name    = "${local.name}-server"
      Project = var.project_name # Lambda の SSM SendCommand 条件が参照する
    }
  }

  # ボリュームにもタグを伝播させる。これが無いと EBS の費用がコスト集計で
  # プロジェクトに紐づかず、孤児ボリュームの特定もできない。
  tag_specifications {
    resource_type = "volume"

    tags = {
      Name    = "${local.name}-server"
      Project = var.project_name
    }
  }

  # Canonical が新しい Ubuntu を出すたびに SSM パラメータの値が変わるため、
  # 何もしていなくても plan に差分が出続ける。それを無視する設定。
  #
  # 代償として AMI が自動更新されなくなる。OS を更新したくなったら
  # 一度この 3 行をコメントアウトして apply する。
  # (セキュリティ更新自体は Ubuntu の unattended-upgrades が起動中に行う)
  lifecycle {
    ignore_changes = [image_id]
  }
}

resource "aws_autoscaling_group" "server" {
  name             = "${local.name}-server"
  min_size         = 0
  max_size         = 1 # 同時起動台数の上限。排他の正しさは S3 ロックが担う (DESIGN.md)
  desired_capacity = 0

  # 起動先の候補サブネット。全 AZ を渡すことで、ある AZ のスポットが枯れても
  # 別の AZ で起動できる (network.tf の locals.azs 参照)。
  vpc_zone_identifier = [for s in aws_subnet.public : s.id]

  # AWS が「この枠はそろそろ回収されそう」と判断した時点で先回りして置換を始める。
  # 実際の中断通知 (2 分前) を待たないぶん、ダウンタイムが短くなる。
  # 旧インスタンスの終了は下の LifecycleHook を通るので、セーブは保証される。
  capacity_rebalance = true

  # EC2 のステータスチェック (ハードウェア障害・ネットワーク到達性・OS 起動) のみ。
  # ゲームが応答しているかは見ていない。ASG に落とさせると強制終了になり
  # セーブの猶予が無いため、ゲームの死活は別の手段で扱う方針。
  health_check_type = "EC2"

  # 起動直後はステータスチェックが initializing のまま数十秒揺らぐことがあるため、
  # その間の一時的な失敗判定で置換されないよう猶予を置く。
  health_check_grace_period = 120

  mixed_instances_policy {
    instances_distribution {
      # 「常時オンデマンドで確保する台数」と「それを超える分のオンデマンド比率」。
      # 両方 0 = 100% スポット。安さ最優先で、中断はシステム側で吸収する方針。
      # キャパシティ枯渇で起動できない時は README のオンデマンド切替手順を使う。
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0

      # 候補プールの中から「価格が安く、かつ中断されにくい」ものを選ぶ戦略。
      # 単純な lowest-price だと、最安だが枯渇寸前のプールを掴んで
      # すぐ中断される、という事故が起きやすい。
      spot_allocation_strategy = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.server.id

        # 常に最新版を使う。これにより user_data やタグの変更が
        # 次回起動時に自動で反映される (テンプレートの版指定が不要)。
        version = "$Latest"
      }

      # 起動テンプレートにインスタンスタイプを書かず、ここで候補を列挙する。
      # 「タイプ × AZ」の組がそのままスポットのキャパシティプール数になり
      # (11 タイプ × 4 AZ = 44 プール)、多いほど空きプールに逃げられて
      # 中断されにくい。EBS だと AZ 固定になるのでこれができない。
      #
      # dynamic は「変数の配列から同じブロックを繰り返し生成する」書き方。
      # var.instance_types の要素数だけ override ブロックが展開される。
      dynamic "override" {
        for_each = var.instance_types

        content {
          instance_type = override.value
        }
      }
    }
  }

  # desired の 0<->1 は Lambda (/pal start・stop) が操作する。
  # これが無いと、遊んでいる最中に terraform apply しただけで
  # desired が 0 に戻され、サーバーが落ちてしまう。
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-server"
    propagate_at_launch = false
  }
}

# 終了前に guardian へセーブの猶予を与えるフック。
# guardian が Terminating:Wait を検知 → 安全停止 → CompleteLifecycleAction で解放。
# 300 秒応答がなければ ASG は強制終了する (その場合も層 1 の定期バックアップが効く)。
resource "aws_autoscaling_lifecycle_hook" "terminating" {
  name                   = "${local.name}-save-before-terminate"
  autoscaling_group_name = aws_autoscaling_group.server.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = 300
  default_result         = "CONTINUE"
}

# ---------------------------------------------------------------------------
# 起動テンプレート + AutoScalingGroup
#   Discord の start/stop は desired capacity の 0<->1 切替として実装される。
# ---------------------------------------------------------------------------

resource "aws_launch_template" "server" {
  name          = "${local.name}-server"
  image_id      = data.aws_ssm_parameter.ubuntu_ami.value
  ebs_optimized = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [aws_security_group.server.id]

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      delete_on_termination = true # インスタンスは使い捨て。状態は S3 が持つ
      encrypted             = true
    }
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 必須
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # user_data は S3 からスクリプト一式を取って install.sh に委譲する薄いラッパー。
  # 本体のロジックを S3 側に置くことで、修正が AMI 再作成なしに次回起動から反映される。
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
    extra_settings = join(",", [
      for k, v in var.extra_pal_settings : "${k}=${v}"
    ])
  }))

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name    = "${local.name}-server"
      Project = var.project_name # Lambda の SSM SendCommand 条件が参照する
    }
  }

  # AMI (SSM パラメータ) の更新だけでテンプレートの差分が出続けるのを防ぐ。
  lifecycle {
    ignore_changes = [image_id]
  }
}

resource "aws_autoscaling_group" "server" {
  name             = "${local.name}-server"
  min_size         = 0
  max_size         = 1 # 同時起動台数の上限。排他の正しさは S3 ロックが担う (DESIGN.md)
  desired_capacity = 0

  vpc_zone_identifier = [for s in aws_subnet.public : s.id]

  # スポット中断の予兆 (リバランス推奨) を受けて先回りで置換を始める。
  capacity_rebalance = true

  # 起動直後の置換抑制。ヘルスチェックは EC2 標準のみ (ゲームの死活は自前監視)。
  health_check_type         = "EC2"
  health_check_grace_period = 300

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0 # 100% スポット
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.server.id
        version            = "$Latest"
      }

      # タイプ × AZ の組がそのままスポットのキャパシティプール数になる。
      # 多いほど「安くて空いているプール」に逃げられ、中断されにくい。
      dynamic "override" {
        for_each = var.instance_types

        content {
          instance_type = override.value
        }
      }
    }
  }

  # desired の 0<->1 は Lambda が操作するため Terraform では追わない。
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

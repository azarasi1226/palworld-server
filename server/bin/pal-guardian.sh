#!/usr/bin/env bash
# ★中断検知の心臓部 (DESIGN.md 層 2)。5 秒間隔で 3 系統のシグナルを監視し、
# どれか 1 つでも立ったら即座に安全停止シーケンスへ入る。
#
#   1. Spot 中断通知      IMDS spot/instance-action           (猶予 約 2 分)
#   2. リバランス推奨     IMDS events/recommendations/rebalance (中断通知より早い)
#   3. ASG ライフサイクル Terminating:Wait                     (猶予 300 秒)
source /opt/palworld/lib/common.sh

IID=$(instance_id)
ASG_CHECK_INTERVAL=3 # describe は 15 秒に 1 回に間引く (5s ループ × 3)
tick=0

log "guardian started (instance=$IID)"

while true; do
  # 停止完了後は Terminating:Wait のフック解放だけが残タスク。
  # exit せずループを続けるのは、その解放役が guardian 自身だから。
  if [ ! -f "$STATE_DIR/stopped" ]; then
    # --- 1. Spot 中断通知 (404 = 無し) -------------------------------------
    if imds_get "meta-data/spot/instance-action" >/dev/null; then
      log "SIGNAL: spot interruption notice"
      /opt/palworld/bin/pal-graceful-stop.sh spot || true
    fi

    # --- 2. リバランス推奨 -------------------------------------------------
    if imds_get "meta-data/events/recommendations/rebalance" >/dev/null; then
      log "SIGNAL: rebalance recommendation"
      /opt/palworld/bin/pal-graceful-stop.sh rebalance || true
    fi
  fi

  # --- 3. ASG ライフサイクル (API なので間引く) ----------------------------
  tick=$(( (tick + 1) % ASG_CHECK_INTERVAL ))
  if [ "$tick" = "0" ]; then
    STATE=$($AWS autoscaling describe-auto-scaling-instances --instance-ids "$IID" \
      --query "AutoScalingInstances[0].LifecycleState" --output text 2>/dev/null || true)

    if [ "$STATE" = "Terminating:Wait" ]; then
      if [ -f "$STATE_DIR/stopped" ]; then
        # 自発停止 (idle/manual) 済み。セーブは完了しているのでフック解放のみ。
        log "already stopped; completing lifecycle hook"
        ASG_NAME=$($AWS autoscaling describe-auto-scaling-instances --instance-ids "$IID" \
          --query "AutoScalingInstances[0].AutoScalingGroupName" --output text 2>/dev/null || true)
        $AWS autoscaling complete-lifecycle-action \
          --auto-scaling-group-name "$ASG_NAME" \
          --lifecycle-hook-name "$PAL_PROJECT-save-before-terminate" \
          --instance-id "$IID" \
          --lifecycle-action-result CONTINUE 2>/dev/null || true
        exit 0
      fi
      log "SIGNAL: ASG lifecycle Terminating:Wait"
      /opt/palworld/bin/pal-graceful-stop.sh lifecycle
      exit 0
    fi
  fi

  sleep 5
done

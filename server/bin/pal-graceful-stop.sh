#!/usr/bin/env bash
# 安全停止シーケンス (DESIGN.md 層 3)。緊急 (スポット中断) と通常 (stop/idle) で共用。
#
#   pal-graceful-stop.sh spot|rebalance|lifecycle|idle|manual
#
# 冪等: guardian の複数シグナルや二重起動があっても 1 回しか走らない。
source /opt/palworld/lib/common.sh

REASON="${1:-manual}"

exec 8>"$STATE_DIR/stop.flock"
if ! flock -n 8; then
  log "stop sequence already running (reason=$REASON), exiting"
  exit 0
fi
if [ -f "$STATE_DIR/stopped" ]; then
  log "stop sequence already completed"
  exit 0
fi

START_EPOCH=$(date +%s)
log "graceful stop start (reason=$REASON)"

case "$REASON" in
  spot)      notify "⚠️ スポット中断の警告を受信しました" "約 2 分後に強制終了されます。セーブして退避します。切断される可能性があります。" yellow ;;
  rebalance) notify "⚠️ スポット中断の予兆を検知しました" "先回りしてセーブ・退避します。数分後に別のサーバーで復帰します。" yellow ;;
  idle)      notify "💤 無人のため自動停止します" "${PAL_IDLE_MINUTES} 分間接続がありませんでした。セーブして停止します。" blue ;;
  lifecycle) notify "🛑 停止要求を受信しました" "セーブして停止します。" blue ;;
  *)         notify "🛑 停止します" "セーブして停止します。" blue ;;
esac

rcon_broadcast "SERVER_SAVING_AND_SHUTTING_DOWN"

# --- セーブ + アップロード (失敗しても続行し、結果通知でロスト見込みを出す) ---
BACKUP_OK=0
if /opt/palworld/bin/pal-backup.sh --final; then
  BACKUP_OK=1
fi

# --- サーバープロセス停止 ---------------------------------------------------
# RCON Shutdown が効かない場合に備え systemd 停止 (SIGTERM → 猶予 → SIGKILL) へ倒す。
rcon "Shutdown 1" 2>/dev/null || true
sleep 2
systemctl stop palworld.service 2>/dev/null || true

# --- ログ退避 ---------------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ)
journalctl -u palworld -u pal-guardian --no-pager --since "-6 hours" \
  > "$WORK_DIR/server-$TS.log" 2>/dev/null || true
$AWS s3 cp "$WORK_DIR/server-$TS.log" "$S3/logs/server-$TS.log" --no-progress >/dev/null 2>&1 || true

# --- status.json を停止状態へ ----------------------------------------------
/opt/palworld/bin/pal-status.sh stopped 2>/dev/null || true

# --- ロック解放 (必ずセーブのアップロード後) --------------------------------
lock_release

touch "$STATE_DIR/stopped"

# --- ASG への後始末 ---------------------------------------------------------
IID=$(instance_id)
ASG_INFO=$($AWS autoscaling describe-auto-scaling-instances --instance-ids "$IID" \
  --query "AutoScalingInstances[0]" --output json 2>/dev/null || echo "{}")
ASG_NAME=$(echo "$ASG_INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("AutoScalingGroupName",""))' 2>/dev/null || true)
LC_STATE=$(echo "$ASG_INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("LifecycleState",""))' 2>/dev/null || true)

if [ "$LC_STATE" = "Terminating:Wait" ]; then
  # ライフサイクルフックを解放して終了を進めさせる。
  $AWS autoscaling complete-lifecycle-action \
    --auto-scaling-group-name "$ASG_NAME" \
    --lifecycle-hook-name "$PAL_PROJECT-save-before-terminate" \
    --instance-id "$IID" \
    --lifecycle-action-result CONTINUE 2>/dev/null || true
elif [ "$REASON" = "idle" ] || [ "$REASON" = "manual" ]; then
  # 自発停止: desired を 0 にして自分を終了させる。この後 Terminating:Wait が来るが、
  # stopped フラグを見た guardian が再セーブせずフック解放だけを行う。
  [ -n "$ASG_NAME" ] && $AWS autoscaling set-desired-capacity \
    --auto-scaling-group-name "$ASG_NAME" --desired-capacity 0 2>/dev/null || true
fi

# --- 結果通知 (ロスト見込みの明示) ------------------------------------------
ELAPSED=$(( $(date +%s) - START_EPOCH ))
if [ "$BACKUP_OK" = "1" ]; then
  case "$REASON" in
    spot|rebalance)
      notify "✅ 緊急セーブ完了 (${ELAPSED} 秒)" "ロスト: 0 分\n別のサーバーで自動復帰します。数分後に再接続してください。\n接続先: $PAL_FQDN:$PAL_GAME_PORT" green ;;
    *)
      notify "✅ セーブして停止しました (${ELAPSED} 秒)" "再開するには /pal start を実行してください。" green ;;
  esac
else
  LAST=$(cat "$STATE_DIR/last-backup-epoch" 2>/dev/null || echo 0)
  if [ "$LAST" -gt 0 ]; then
    LOST_MIN=$(( ( $(date +%s) - LAST + 59 ) / 60 ))
    LAST_STR=$(date -d "@$LAST" "+%H:%M")
    notify "🚨 最終セーブに失敗しました" "ロスト見込み: 約 ${LOST_MIN} 分 (${LAST_STR} 時点の定期バックアップまで巻き戻ります)" red
  else
    notify "🚨 最終セーブに失敗しました" "直前の定期バックアップ時点まで巻き戻ります。" red
  fi
fi

log "graceful stop done (reason=$REASON, backup_ok=$BACKUP_OK, ${ELAPSED}s)"

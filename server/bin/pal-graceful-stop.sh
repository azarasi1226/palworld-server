#!/usr/bin/env bash
# 安全停止シーケンス (DESIGN.md 層 3)。緊急 (スポット中断) と通常 (stop/idle) で共用。
#
#   pal-graceful-stop.sh spot|lifecycle|idle|manual
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

# --- 停止原因の分類 ----------------------------------------------------------
# lifecycle (ASG からの終了指示) は「ユーザーの /pal stop」と「スポット起因の
# 置き換え」の両方で発生するため、通知が区別できるよう原因を判定する。
#   1. IMDS にスポット回収の警告/予兆が出ている -> スポット起因
#   2. ASG の desired が 0                       -> ユーザーの停止操作
#   3. desired が 1 のままの置き換え             -> AWS 都合 (ヘルスチェック等)
CAUSE="$REASON"
if [ "$REASON" = "lifecycle" ]; then
  if imds_get "meta-data/spot/instance-action" >/dev/null \
     || imds_get "meta-data/events/recommendations/rebalance" >/dev/null; then
    CAUSE="spot_replace"
  else
    DESIRED=$($AWS autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$PAL_PROJECT-server" \
      --query "AutoScalingGroups[0].DesiredCapacity" --output text 2>/dev/null || echo "?")
    case "$DESIRED" in
      0) CAUSE="user_stop" ;;
      "?") CAUSE="lifecycle" ;; # 判定失敗時は従来どおりの汎用文言に落とす
      *) CAUSE="replace_other" ;;
    esac
  fi
fi
log "graceful stop start (reason=$REASON, cause=$CAUSE)"

# 定期タイマーを先に止める。放置すると停止後に status タイマーが
# ロックを再作成し、次のインスタンスが陳腐化判定の 90 秒を無駄に待つ。
# (pal-idle / pal-guardian は本スクリプトの呼び出し元になりうるため止めない)
systemctl stop pal-backup.timer pal-status.timer 2>/dev/null || true

# AWS 都合の停止 (スポット中断・回収の予兆・ヘルスチェック等) は 1 つの文言に統一する。
#
# 内部では原因を分けて判定しているが、それは猶予時間が違う (2 分 / 300 秒) という
# 内部の事情でしかなく、利用者がとる行動は「数分待って再接続する」で全く同じ。
# 文言を分けると「どう違うのか」を考えさせるだけで、判断の助けにならない。
# 区別が必要になるのはログを見るときなので、原因は log に残す (通知には出さない)。
#
# 復帰の案内も 1 文に固定する。Route53 で同じホスト名に戻るため、
# 経路によって書き分ける理由がない。
RECOVER_TEXT="数分後に同じアドレスへ自動復帰します。そのまま再接続してください。"
AWS_STOP_TEXT="AWS の都合でこのサーバーが停止されます。誰かが停止したわけではありません。\nセーブしてから別のサーバーへ引っ越します。\n$RECOVER_TEXT"

case "$CAUSE" in
  spot|spot_replace|replace_other)
    notify "🔁 AWS 都合でサーバーを引っ越します" "$AWS_STOP_TEXT" yellow ;;
  user_stop)     notify "🛑 停止要求を受け付けました" "【原因: ユーザー操作 (/pal stop・restart または管理操作)】\nセーブして停止します。" blue ;;
  idle)          notify "💤 無人のため自動停止します" "【原因: ${PAL_IDLE_MINUTES} 分間接続なし (消し忘れ防止)】\nセーブして停止します。再開は /pal start で。" blue ;;
  lifecycle)     notify "🛑 停止要求を受信しました" "セーブして停止します。" blue ;;
  *)             notify "🛑 停止します" "【原因: サーバー上での手動実行】\nセーブして停止します。" blue ;;
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
journalctl -u palworld -u pal-guardian --no-pager --since -6h \
  > "$WORK_DIR/server-$TS.log" 2>/dev/null || true
$AWS s3 cp "$WORK_DIR/server-$TS.log" "$S3/logs/server-$TS.log" --no-progress >/dev/null 2>&1 || true

# --- 停止確定 ---------------------------------------------------------------
# フラグを先に立ててから status 発行・ロック解放を行う。
# 逆順だと並走中の status タイマーが解放後にロックを再作成しうる。
touch "$STATE_DIR/stopped"
/opt/palworld/bin/pal-status.sh stopped 2>/dev/null || true

# --- ロック解放 (必ずセーブのアップロード後) --------------------------------
lock_release

# --- 結果通知 (ロスト見込みの明示) ------------------------------------------
# ★ ASG への後始末より先に送ること。
#   ライフサイクルフックを解放すると AWS はその場でインスタンスを削除するため、
#   後に回すと通知を送り切る前に電源が切れる (実際にスポット回収時だけ
#   「緊急セーブ完了」が届かない現象になっていた。セーブ自体は成功していた)。
ELAPSED=$(( $(date +%s) - START_EPOCH ))
if [ "$BACKUP_OK" = "1" ]; then
  case "$CAUSE" in
    spot|spot_replace|replace_other)
      notify "✅ 緊急セーブ完了 (${ELAPSED} 秒)" "ロスト: 0 分\n$RECOVER_TEXT\n接続先: $PAL_FQDN:$PAL_GAME_PORT" green ;;
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

# --- ASG への後始末 (ここから先はいつ電源が切れてもよい) ---------------------
IID=$(instance_id)
# --query で 2 値まとめて取り出す (python プロセスを挟まない。緊急停止は 2 分制限)
read -r ASG_NAME LC_STATE <<< "$($AWS autoscaling describe-auto-scaling-instances \
  --instance-ids "$IID" \
  --query "AutoScalingInstances[0].[AutoScalingGroupName,LifecycleState]" \
  --output text 2>/dev/null || echo "")"

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

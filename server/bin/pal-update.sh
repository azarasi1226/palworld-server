#!/usr/bin/env bash
# ゲーム本体を最新版に更新する (/pal update から SSM 経由で呼ばれる)。
#
# 起動処理から更新を分離しているのは、
#   ・更新失敗がそのまま起動失敗になるのを避けるため
#   ・意図しないタイミングでバージョンが上がるのを防ぐため (セーブ互換の事故)
# の 2 点による。
#
# インスタンスは動いたまま、ゲームプロセスだけを止めて入れ替える。
# 「サーバー停止中に更新」はできない (停止 = インスタンスごと終了しており、
#  steamcmd を走らせる機械が存在しないため)。
source /opt/palworld/lib/common.sh

exec 7>"$STATE_DIR/update.flock"
if ! flock -n 7; then
  echo "UPDATE_RESULT: already running"
  exit 1
fi

CURRENT=$(buildid_local)

# --- 1. 前提の確認 ----------------------------------------------------------
# 遊んでいる最中に割り込まない。更新は意図的なメンテナンス作業なので、
# 警告して強制するより単純に断るほうがよい。
#
# ここは Lambda 側の事前チェックをすり抜けた場合の最終判定でもある
# (Lambda が見る status.json は最大 30 秒古く、その間に誰か入ることがある)。
# そのため中止したことを、コマンドの実行者だけでなく
# 通知チャンネルとゲーム内の両方に伝える。
#   ・SSM の応答が遅れると Lambda の返信が「実行中です」で終わり、
#     中止した事実がどこにも残らないため (通知チャンネルで補う)
#   ・遊んでいる本人は誰かが更新したがっていることを知る手段がないため
#     (ゲーム内 Broadcast で伝える)
if systemctl is-active --quiet palworld; then
  PLAYERS=$(rcon "ShowPlayers" 2>/dev/null || true)
  COUNT=$(echo "$PLAYERS" | tail -n +2 | sed '/^\s*$/d' | wc -l)
  if [ "${COUNT:-0}" -gt 0 ]; then
    log "update refused: $COUNT player(s) online"
    rcon_broadcast "UPDATE_REQUESTED_PLEASE_LOGOUT_WHEN_READY"
    notify "⛔ 更新を中止しました" \
      "現在 ${COUNT} 人が接続中です。全員が退出してから \`/pal update\` を実行してください。\nゲーム内にも退出のお願いを表示しました。" yellow
    echo "UPDATE_RESULT: players_online $COUNT"
    exit 1
  fi
fi

LATEST=$(buildid_latest)
log "update start (current=$CURRENT latest=$LATEST)"

if [ "$LATEST" != "0" ] && [ "$LATEST" = "$CURRENT" ]; then
  log "already up to date"
  echo "UPDATE_RESULT: already_latest $CURRENT"
  exit 0
fi

notify "🔄 サーバーを更新しています" \
  "現在: build $CURRENT\n最新: build ${LATEST/0/不明}\n\nセーブしてから更新します。完了まで 2〜4 分かかります。" yellow

# --- 2. 更新前の状態を退避 --------------------------------------------------
# 新バージョンで一度起動すると旧バージョンには戻せなくなることがあるため、
# 更新直前の断面を専用の名前で残す (30 日保持)。
if systemctl is-active --quiet palworld; then
  rcon_broadcast "SERVER_UPDATING_PLEASE_WAIT"
  if /opt/palworld/bin/pal-backup.sh --final; then
    $AWS s3 cp "$S3/saves/latest.tar.zst" \
      "$S3/saves/archive/pre-update-$CURRENT.tar.zst" --no-progress >/dev/null 2>&1 \
      && log "pre-update archive saved (build $CURRENT)"
  else
    log "FATAL: backup failed; aborting update to protect the save"
    notify "🚨 更新を中止しました" "更新前のバックアップに失敗したため、安全のため更新を行いませんでした。\nサーバーはそのまま稼働しています。" red
    echo "UPDATE_RESULT: backup_failed"
    exit 1
  fi
fi

# --- 3. ゲームプロセスを止めて入れ替える ------------------------------------
log "stopping palworld.service"
systemctl stop palworld.service 2>/dev/null || true

run_steamcmd || log "steamcmd returned non-zero; verifying actual state"

NEW=$(buildid_local)
if [ ! -x "$PAL_DIR/PalServer.sh" ] || [ "$NEW" = "0" ]; then
  log "FATAL: game files are broken after update (buildid=$NEW)"
  notify "🚨 更新に失敗しました" \
    "ゲームファイルが壊れています。/pal restart でクリーンインストールを試してください。\nセーブは更新前の状態で S3 に保全されています。" red
  echo "UPDATE_RESULT: failed"
  exit 1
fi

# --- 4. サーバーを戻す ------------------------------------------------------
log "starting palworld.service (buildid=$NEW)"
systemctl start palworld.service

# 次回起動を速くするため、新しいバージョンでキャッシュを作り直す。
# SSM の実行が先に終わっても完走できるよう、独立したユニットとして起動する。
if ! systemd-run --unit=pal-post-boot --collect --quiet \
  /opt/palworld/bin/pal-post-boot.sh 2>/dev/null; then
  log "WARN: systemd-run failed; refreshing cache in the background instead"
  ( upload_game_cache "$NEW" ) &
fi

# RCON が応答するまで待ってから完了を知らせる。
READY=0
for _ in $(seq 1 36); do
  if rcon "Info" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 5
done

if [ "$NEW" = "$CURRENT" ]; then
  notify "ℹ️ 更新はありませんでした" "build $NEW のままです。サーバーは再起動しました。" blue
  echo "UPDATE_RESULT: no_change $NEW"
elif [ "$READY" = "1" ]; then
  notify "✅ 更新が完了しました" \
    "build $CURRENT → **$NEW**\n\nクライアント側も最新版に更新してから接続してください。\n接続先: $PAL_FQDN:$PAL_GAME_PORT" green
  echo "UPDATE_RESULT: updated $CURRENT $NEW"
else
  notify "⚠️ 更新しましたが起動を確認できません" \
    "build $CURRENT → $NEW に更新しましたが、RCON が応答しません。\n/pal status で確認してください。" yellow
  echo "UPDATE_RESULT: updated_not_ready $CURRENT $NEW"
fi

/opt/palworld/bin/pal-status.sh running 2>/dev/null || true
log "update done (current=$CURRENT new=$NEW ready=$READY)"

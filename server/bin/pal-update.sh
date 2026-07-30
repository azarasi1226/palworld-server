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
  COUNT=$(player_count || true)
  # unknown (RCON 不応答) のときは判定できないので、止めずに進める。
  # サーバーが応答しない状態なら、そもそも誰も遊べていない。
  if [ "$COUNT" != "unknown" ] && [ "${COUNT:-0}" -gt 0 ]; then
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

# ゲーム本体を消してからクリーンインストールする。
#
# S3 キャッシュから復元した状態に対して steamcmd の差分更新は成立しない。
#   Update state (0x0) : Timed out waiting for update to start, bailing.
#   Error! App '2394010' state is 0x6 after update job.
# 復元でファイルの状態が steamcmd の想定と噛み合わなくなるためで、
# リトライしても必ず同じ結果になる (実際に何度も踏んだ)。
# 「差分を試してから諦める」と 4 分無駄になるので、最初からクリーンにする。
#
# ★ Pal/Saved を退避してから消すこと。ここにはワールドだけでなく
#   GameUserSettings.ini (DedicatedServerName = どのワールドを開くか) も入っており、
#   消すとサーバーが新規ワールドを作ってしまう (キャラクリやり直しになる)。
SAVED_HOLD="$WORK_DIR/saved-hold"
rm -rf "$SAVED_HOLD"
if [ -d "$PAL_DIR/Pal/Saved" ]; then
  mv "$PAL_DIR/Pal/Saved" "$SAVED_HOLD"
  log "held Pal/Saved aside ($(du -sh "$SAVED_HOLD" 2>/dev/null | cut -f1))"
fi

rm -rf "${PAL_DIR:?}"/*
rm -rf /home/palworld/.local/share/Steam/steamapps/downloading \
       /home/palworld/.local/share/Steam/steamapps/temp
chown -R palworld:palworld "$PAL_HOME"

run_steamcmd || log "steamcmd returned non-zero; verifying actual state"

# セーブを戻す。ここで失敗すると新規ワールドで起動してしまうため、
# 復元できなければ起動させずに中止する (S3 には退避済みなので復旧可能)。
if [ -d "$SAVED_HOLD" ]; then
  mkdir -p "$PAL_DIR/Pal"
  if mv "$SAVED_HOLD" "$PAL_DIR/Pal/Saved"; then
    chown -R palworld:palworld "$PAL_DIR/Pal/Saved"
    log "restored Pal/Saved"
  else
    log "FATAL: could not restore Pal/Saved"
    notify "🚨 更新後のセーブ復元に失敗しました" \
      "サーバーは起動しません。セーブは S3 (saves/latest.tar.zst) に保全されています。\n/pal restart で S3 から復元してください。" red
    echo "UPDATE_RESULT: failed"
    exit 1
  fi
fi

NEW=$(buildid_local)
if [ ! -x "$PAL_DIR/PalServer.sh" ] || [ "$NEW" = "0" ]; then
  log "FATAL: game files are broken after update (buildid=$NEW)"
  notify "🚨 更新に失敗しました" \
    "ゲーム本体を取得できませんでした。Steam 側の障害の可能性があります。\nセーブは S3 に保全されています。時間をおいて /pal restart を試してください。" red
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

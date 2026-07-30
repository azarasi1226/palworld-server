#!/usr/bin/env bash
# 無人検知 (消し忘れ対策)。60 秒ごとに RCON ShowPlayers で接続人数を確認し、
# 0 人が PAL_IDLE_MINUTES 分続いたら安全停止して desired=0 にする。
source /opt/palworld/lib/common.sh

if [ "$PAL_IDLE_MINUTES" = "0" ]; then
  log "idle shutdown disabled"
  exit 0
fi

# 起動直後に誰も繋ぐ前に落ちるのを防ぐ猶予。
log "boot grace: ${PAL_GRACE_MINUTES}m before idle detection starts"
sleep $(( PAL_GRACE_MINUTES * 60 ))

# RCON 不応答が続いたら知らせるまでの時間。
# 無人判定が成立しないため、ここで知らせないと課金だけが続く (下記参照)。
RCON_DEAD_MINUTES=10

IDLE_SINCE=0
UNKNOWN_SINCE=0
UNKNOWN_NOTIFIED=0
log "idle watcher started (threshold ${PAL_IDLE_MINUTES}m)"

while true; do
  sleep 60
  [ -f "$STATE_DIR/stopped" ] && exit 0

  COUNT=$(player_count || true)
  if [ "$COUNT" = "unknown" ]; then
    # RCON 不調では停止しない (誰か遊んでいる最中に落とすのが最悪のため)。
    # カウンタもリセットして、応答が戻ってから数え直す。
    log "WARN: rcon unreachable; skipping idle check"
    IDLE_SINCE=0

    # ただし黙って続けるのは危険。RCON が死んでいる間は無人判定が永久に
    # 成立しないため、ゲームがクラッシュループに入ると誰も止めないまま
    # 課金が続く。しかも status.json は players:[] を返すので、
    # 外からは「0 人で正常稼働」に見えてしまう。
    # 自動停止はしない (RCON だけ壊れてゲームは動いている可能性があり、
    # 遊んでいる人を蹴る判断は人に委ねる)。1 回だけ知らせる。
    NOW=$(date +%s)
    [ "$UNKNOWN_SINCE" = "0" ] && UNKNOWN_SINCE=$NOW
    if [ "$UNKNOWN_NOTIFIED" = "0" ] \
      && [ $(( (NOW - UNKNOWN_SINCE) / 60 )) -ge "$RCON_DEAD_MINUTES" ]; then
      log "rcon unreachable for ${RCON_DEAD_MINUTES}m; notifying"
      notify "⚠️ ゲームが応答していません" \
        "${RCON_DEAD_MINUTES} 分間サーバーに応答がありません。クラッシュしている可能性があります。\nこの状態では無人自動停止も働かないため、課金が続きます。\n\`/pal restart\` で復旧するか、\`/pal stop\` で停止してください。" yellow
      UNKNOWN_NOTIFIED=1
    fi
    continue
  fi

  # 応答が戻った。次に落ちたときも改めて知らせる。
  UNKNOWN_SINCE=0
  UNKNOWN_NOTIFIED=0

  if [ "$COUNT" -gt 0 ]; then
    IDLE_SINCE=0
    continue
  fi

  NOW=$(date +%s)
  [ "$IDLE_SINCE" = "0" ] && IDLE_SINCE=$NOW

  IDLE_MIN=$(( (NOW - IDLE_SINCE) / 60 ))
  if [ "$IDLE_MIN" -ge "$PAL_IDLE_MINUTES" ]; then
    log "idle for ${IDLE_MIN}m; initiating shutdown"
    /opt/palworld/bin/pal-graceful-stop.sh idle
    exit 0
  fi
done

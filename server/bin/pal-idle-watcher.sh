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

IDLE_SINCE=0
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
    continue
  fi

  echo "$COUNT" > "$STATE_DIR/player-count"

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

#!/usr/bin/env bash
# status.json を S3 へ発行し、ロックのハートビートを更新する (30 秒ごと)。
# Lambda の /pal status /pal players はこれを読む。
#
#   pal-status.sh [running|starting|stopped]
source /opt/palworld/lib/common.sh

STATE="${1:-running}"

PLAYERS_JSON="[]"
COUNT=0
if [ "$STATE" = "running" ]; then
  RAW=$(rcon "ShowPlayers" 2>/dev/null || true)
  if [ -n "$RAW" ]; then
    PLAYERS_JSON=$(echo "$RAW" | python3 -c '
import json, sys
names = []
for line in sys.stdin.read().splitlines()[1:]:  # 先頭はヘッダ行
    line = line.strip()
    if line:
        names.append(line.split(",")[0])
print(json.dumps(names, ensure_ascii=False))
')
    COUNT=$(echo "$PLAYERS_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  fi
fi

LAST_BACKUP=$(cat "$STATE_DIR/last-backup-epoch" 2>/dev/null || echo 0)
SAVE_SIZE=0
LV=$(find "$SAVE_DIR" -name "Level.sav" 2>/dev/null | head -n 1)
[ -n "$LV" ] && SAVE_SIZE=$(stat -c %s "$LV")

ITYPE=$(imds_get "meta-data/instance-type" || echo "unknown")
IP=$(public_ip || echo "unknown")

cat > "$STATE_DIR/status.json" <<EOF
{
  "state": "$STATE",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "updated_epoch": $(date -u +%s),
  "instance_id": "$(instance_id)",
  "instance_type": "$ITYPE",
  "public_ip": "$IP",
  "fqdn": "$PAL_FQDN",
  "port": $PAL_GAME_PORT,
  "player_count": $COUNT,
  "players": $PLAYERS_JSON,
  "last_backup_epoch": $LAST_BACKUP,
  "level_sav_bytes": $SAVE_SIZE,
  "boot_epoch": $(cat "$STATE_DIR/boot-epoch" 2>/dev/null || echo 0)
}
EOF

$AWS s3 cp "$STATE_DIR/status.json" "$S3/status.json" \
  --content-type application/json --no-progress >/dev/null

# 稼働中はロックのハートビートも一緒に更新する (排他制御)。
if [ "$STATE" != "stopped" ] && [ ! -f "$STATE_DIR/stopped" ]; then
  lock_write
fi

#!/usr/bin/env bash
# status.json を S3 へ発行し、ロックのハートビートを更新する (30 秒ごと)。
# Lambda の /pal status /pal players はこれを読む。
#
#   pal-status.sh [running|starting|stopped]
source /opt/palworld/lib/common.sh

STATE="${1:-running}"

# 停止シーケンス完了後もタイマーは動き続けるため、"running" で
# 停止状態の status.json を上書きしてしまわないようにする。
[ -f "$STATE_DIR/stopped" ] && STATE="stopped"

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

# メモリ・スワップ・ディスク。
# CloudWatch はハイパーバイザー側からしか見えないためこれらを取得できない。
# エージェント (カスタムメトリクス月 $0.30/個) を入れる代わりにここで拾う。
read -r MEM_USED_MB MEM_TOTAL_MB SWAP_USED_MB SWAP_TOTAL_MB <<< "$(
  free -m | awk '/^Mem:/{m=$3; t=$2} /^Swap:/{s=$3; st=$2} END{print m, t, s+0, st+0}'
)"
read -r DISK_USED_GB DISK_TOTAL_GB <<< "$(
  df -BG --output=used,size / | tail -1 | tr -d 'G'
)"

# CPU 使用率: /proc/stat の累積値を前回実行時 (= 30 秒前) と比較して算出する。
# 瞬間値のサンプリング (vmstat 1 2 等) と違い sleep が不要で、
# 30 秒平均になるぶんノイズも少ない。初回は前回値が無いので 0 になる。
CPU_PCT=0
read -r _ cu cn cs ci cw cirq csirq cst _ < /proc/stat
CPU_TOTAL=$((cu + cn + cs + ci + cw + cirq + csirq + cst))
CPU_IDLE=$((ci + cw))
if [ -f "$STATE_DIR/prev-cpu" ]; then
  read -r PREV_TOTAL PREV_IDLE < "$STATE_DIR/prev-cpu"
  DIFF_TOTAL=$((CPU_TOTAL - PREV_TOTAL))
  DIFF_IDLE=$((CPU_IDLE - PREV_IDLE))
  [ "$DIFF_TOTAL" -gt 0 ] && CPU_PCT=$(((DIFF_TOTAL - DIFF_IDLE) * 100 / DIFF_TOTAL))
fi
echo "$CPU_TOTAL $CPU_IDLE" > "$STATE_DIR/prev-cpu"

CORES=$(nproc)
LOAD1=$(cut -d' ' -f1 /proc/loadavg)

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
  "cpu_percent": ${CPU_PCT:-0},
  "cpu_cores": ${CORES:-0},
  "load1": ${LOAD1:-0},
  "mem_used_mb": ${MEM_USED_MB:-0},
  "mem_total_mb": ${MEM_TOTAL_MB:-0},
  "swap_used_mb": ${SWAP_USED_MB:-0},
  "swap_total_mb": ${SWAP_TOTAL_MB:-0},
  "disk_used_gb": ${DISK_USED_GB:-0},
  "disk_total_gb": ${DISK_TOTAL_GB:-0},
  "boot_epoch": $(cat "$STATE_DIR/boot-epoch" 2>/dev/null || echo 0)
}
EOF

$AWS s3 cp "$STATE_DIR/status.json" "$S3/status.json" \
  --content-type application/json --no-progress >/dev/null

# 稼働中はロックのハートビートも一緒に更新する (排他制御)。
if [ "$STATE" != "stopped" ] && [ ! -f "$STATE_DIR/stopped" ]; then
  lock_write
fi

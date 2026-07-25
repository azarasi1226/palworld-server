#!/usr/bin/env bash
# Discord webhook 通知 (A 系統)。
# 使い方: pal-notify.sh "タイトル" "本文" [色: green|yellow|red|blue]
source /opt/palworld/lib/common.sh

TITLE="${1:?title required}"
BODY="${2:-}"
COLOR_NAME="${3:-blue}"

case "$COLOR_NAME" in
  green)  COLOR=5763719 ;;
  yellow) COLOR=16705372 ;;
  red)    COLOR=15548997 ;;
  *)      COLOR=5793266 ;;
esac

WEBHOOK=$($AWS ssm get-parameter --name "/$PAL_PROJECT/discord/webhook_url" \
  --with-decryption --query Parameter.Value --output text)

python3 - "$TITLE" "$BODY" "$COLOR" "$WEBHOOK" <<'PYEOF'
import json, sys, urllib.request

title, body, color, webhook = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
body = body.replace("\\n", "\n")  # 呼び出し側は bash の "...\n..." (リテラル) で渡してくる
payload = {"embeds": [{"title": title, "description": body, "color": color}]}
req = urllib.request.Request(
    webhook,
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "pal-server"},
)
urllib.request.urlopen(req, timeout=10).read()
PYEOF

log "notified: $TITLE"

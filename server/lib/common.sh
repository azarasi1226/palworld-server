#!/usr/bin/env bash
# 全スクリプト共通の関数と定数。source して使う。
# 設定は /etc/palworld/env (user_data が生成) から読む。

set -euo pipefail

# shellcheck source=/dev/null
source /etc/palworld/env

PAL_HOME="/home/palworld"
PAL_DIR="$PAL_HOME/palserver"                      # ゲーム本体
SAVE_DIR="$PAL_DIR/Pal/Saved/SaveGames"            # バックアップ対象
WORK_DIR="/var/lib/palworld"                       # スナップショット・一時ファイル
STATE_DIR="/run/palworld"                          # フラグ類 (tmpfs)
RCON_PORT=25575

S3="s3://$PAL_BUCKET"
AWS="aws --region $PAL_REGION"

mkdir -p "$WORK_DIR" "$STATE_DIR"

log() {
  echo "[$(basename "$0")] $(date -Is) $*"
}

# ---------------------------------------------------------------------------
# IMDSv2
# ---------------------------------------------------------------------------

imds_token() {
  curl -sS -X PUT --max-time 2 \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    "http://169.254.169.254/latest/api/token" 2>/dev/null || true
}

# 200 なら本文を出力し 0、それ以外 (404 = イベント無し) は 1 を返す。
imds_get() {
  local path="$1" token
  token=$(imds_token)
  [ -n "$token" ] || return 1
  curl -sS --max-time 2 -f \
    -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/$path" 2>/dev/null
}

instance_id() {
  # -s: 空ファイル (取得失敗の残骸) はキャッシュとみなさず再取得する
  if [ ! -s "$STATE_DIR/instance-id" ]; then
    imds_get "meta-data/instance-id" > "$STATE_DIR/instance-id"
  fi
  cat "$STATE_DIR/instance-id"
}

public_ip() {
  imds_get "meta-data/public-ipv4"
}

# ---------------------------------------------------------------------------
# RCON
# ---------------------------------------------------------------------------

rcon() {
  # 30 秒ごとの status 発行などで毎回 SSM を叩かないよう、tmpfs にキャッシュする。
  local cache="$STATE_DIR/rcon-pass"
  if [ ! -s "$cache" ]; then
    (umask 077; $AWS ssm get-parameter --name "/$PAL_PROJECT/server/admin_password" \
      --with-decryption --query Parameter.Value --output text > "$cache")
  fi
  python3 /opt/palworld/bin/rcon.py --host 127.0.0.1 --port "$RCON_PORT" \
    --password "$(cat "$cache")" --timeout 10 "$@"
}

# Palworld の Broadcast はスペースを含むと以降が切れるためアンダースコアに置換する。
rcon_broadcast() {
  rcon "Broadcast ${1// /_}" || true
}

# ---------------------------------------------------------------------------
# Discord 通知 (A 系統: インスタンス発)
# ---------------------------------------------------------------------------

notify() {
  /opt/palworld/bin/pal-notify.sh "$@" || true # 通知失敗で本処理を止めない
}

# ---------------------------------------------------------------------------
# S3 排他ロック (世代逆転の防止。DESIGN.md「排他制御」参照)
# ---------------------------------------------------------------------------

lock_write() {
  local id
  id=$(instance_id)
  printf '{"instance_id":"%s","heartbeat":"%s"}\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE_DIR/lock.json"
  $AWS s3 cp "$STATE_DIR/lock.json" "$S3/lock/active.json" --no-progress >/dev/null
}

lock_release() {
  # 自分のロックの場合のみ消す (後続インスタンスのロックを消してしまわないように)。
  local owner
  owner=$($AWS s3 cp "$S3/lock/active.json" - 2>/dev/null | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("instance_id",""))' 2>/dev/null || true)
  if [ "$owner" = "$(instance_id)" ]; then
    $AWS s3 rm "$S3/lock/active.json" >/dev/null 2>&1 || true
  fi
}

# 前任インスタンスのロックが消えるか陳腐化 (90 秒無更新 = 突然死) するまで待つ。
# 復元より前に必ず呼ぶこと。
lock_wait() {
  local body hb age now
  while true; do
    body=$($AWS s3 cp "$S3/lock/active.json" - 2>/dev/null || true)
    [ -z "$body" ] && return 0 # ロック無し

    hb=$(echo "$body" | python3 -c \
      'import json,sys; print(json.load(sys.stdin).get("heartbeat",""))' 2>/dev/null || true)
    if [ -z "$hb" ]; then
      log "lock: broken lock file, ignoring"
      return 0
    fi

    now=$(date -u +%s)
    age=$(( now - $(date -u -d "$hb" +%s 2>/dev/null || echo 0) ))
    if [ "$age" -gt 90 ]; then
      log "lock: stale (${age}s old), previous instance died. taking over"
      return 0
    fi

    log "lock: held by previous instance (heartbeat ${age}s ago), waiting..."
    sleep 5
  done
}

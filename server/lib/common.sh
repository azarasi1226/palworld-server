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
# ゲーム本体 (steamcmd)
#   install.sh (初回導入) と pal-update.sh (更新) の両方から使う。
# ---------------------------------------------------------------------------

STEAMCMD=/usr/games/steamcmd
PAL_APPID=2394010

# 現在インストールされているバージョン。取れなければ 0。
buildid_local() {
  grep -Po '"buildid"\s+"\K[0-9]+' \
    "$PAL_DIR/steamapps/appmanifest_$PAL_APPID.acf" 2>/dev/null || echo 0
}

# Steam 側の最新バージョン。ダウンロードせず問い合わせるだけ (約 10 秒)。
# 取得できなければ 0 を返す。呼び出し側は 0 を「判定不能」として扱うこと。
buildid_latest() {
  sudo -u palworld HOME=/home/palworld "$STEAMCMD" \
    +login anonymous +app_info_update 1 +app_info_print "$PAL_APPID" +quit 2>/dev/null \
    | tr -d '\r' \
    | awk '/"public"/{p=1} p && /"buildid"/ {gsub(/[^0-9]/, "", $2); if ($2 != "") {print $2; exit}}' \
    | head -n1 | grep -E '^[0-9]+$' || echo 0
}

# steamcmd で本体を導入・更新する。出力はログとファイルの両方へ。
# pipefail 下では tee の終了コードが採用されるため PIPESTATUS で拾う。
run_steamcmd() {
  local rc
  set +o pipefail
  sudo -u palworld HOME=/home/palworld "$STEAMCMD" \
    +force_install_dir "$PAL_DIR" +login anonymous \
    +app_update "$PAL_APPID" validate +quit 2>&1 \
    | tee "$WORK_DIR/steamcmd.log" | sed 's/^/  steamcmd| /'
  rc=${PIPESTATUS[0]}
  set -o pipefail
  return "$rc"
}

# ゲーム本体を S3 キャッシュへ保存する。
# tar の終了コード 1 は「読み取り中にファイルが変わった」という警告レベル。
# Pal/Saved は除外しているが、その親 ./Pal の更新時刻はサーバー稼働で変わるため
# 正常時でも 1 になる。中身は無事なので 2 以上だけを致命的として扱う。
upload_game_cache() {
  local build="$1" tar_rc zstd_rc size pipe_rc

  set +o pipefail
  tar -C "$PAL_DIR" --exclude ./Pal/Saved -cf - . | zstd -3 -T0 -q > "$WORK_DIR/gamecache.tar.zst"
  # PIPESTATUS は次のコマンドで消えるため、まず配列ごと退避する。
  pipe_rc=("${PIPESTATUS[@]}")
  tar_rc=${pipe_rc[0]}
  zstd_rc=${pipe_rc[1]}
  set -o pipefail

  size=$(stat -c %s "$WORK_DIR/gamecache.tar.zst" 2>/dev/null || echo 0)

  # 壊れたキャッシュを置くと以降の全起動が壊れるため、必ず検証してから上げる。
  if [ "$tar_rc" -le 1 ] && [ "$zstd_rc" -eq 0 ] && [ "$size" -gt 500000000 ] \
    && zstd -t "$WORK_DIR/gamecache.tar.zst" 2>/dev/null; then
    if $AWS s3 cp "$WORK_DIR/gamecache.tar.zst" "$S3/gamecache/palserver.tar.zst" --no-progress >/dev/null \
      && echo "$build" | $AWS s3 cp - "$S3/gamecache/buildid.txt" >/dev/null; then
      log "game cache uploaded (build=$build size=${size}B)"
      rm -f "$WORK_DIR/gamecache.tar.zst"
      return 0
    fi
    log "WARN: game cache upload failed"
  else
    log "WARN: game cache is unusable (tar=$tar_rc zstd=$zstd_rc size=${size}B)"
  fi
  rm -f "$WORK_DIR/gamecache.tar.zst"
  return 1
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
  owner=$(lock_field instance_id)
  if [ "$owner" = "$(instance_id)" ]; then
    $AWS s3 rm "$S3/lock/active.json" >/dev/null 2>&1 || true
  fi
}

# lock/active.json から 1 項目を取り出す。存在しなければ空文字。
lock_field() {
  $AWS s3 cp "$S3/lock/active.json" - 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))" 2>/dev/null || true
}

# 前任インスタンスのロックが消えるか陳腐化 (90 秒無更新 = 突然死) するまで待つ。
# 復元より前に必ず呼ぶこと。
lock_wait() {
  local hb age now
  while true; do
    hb=$(lock_field heartbeat)
    if [ -z "$hb" ]; then
      # ロックが無い / 壊れている。どちらも待つ理由がない。
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

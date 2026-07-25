#!/usr/bin/env bash
# インスタンス起動時のセットアップ本体 (user_data から exec される)。
# 流れ: OS 準備 → DNS 更新 → ゲーム本体復元 → セーブ復元 → 設定生成 → systemd 起動 → 起動通知
source /opt/palworld/lib/common.sh

date -u +%s > "$STATE_DIR/boot-epoch"
log "install start"

# ---------------------------------------------------------------------------
# 1. OS 準備
# ---------------------------------------------------------------------------
if ! id palworld >/dev/null 2>&1; then
  useradd -m -s /bin/bash palworld
fi

# 16GB でも大人数・長時間の保険としてスワップ 4GB。
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

export DEBIAN_FRONTEND=noninteractive
add-apt-repository -y multiverse >/dev/null
dpkg --add-architecture i386
apt-get update -qq
# steamcmd のライセンス同意を非対話で通す。
echo steam steam/question select "I AGREE" | debconf-set-selections
echo steam steam/license note '' | debconf-set-selections
# steamcmd は Ubuntu では i386 パッケージのみ。
apt-get install -y -qq zstd curl jq >/dev/null
apt-get install -y -qq steamcmd:i386 >/dev/null || apt-get install -y -qq steamcmd >/dev/null

STEAMCMD=/usr/games/steamcmd

# ---------------------------------------------------------------------------
# 2. Route53 UPSERT (TTL 60 — 復帰時の再接続を成立させる必須条件)
# ---------------------------------------------------------------------------
IP=$(public_ip)
cat > "$WORK_DIR/dns.json" <<EOF
{
  "Comment": "palworld server boot",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$PAL_FQDN",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "$IP"}]
    }
  }]
}
EOF
$AWS route53 change-resource-record-sets --hosted-zone-id "$PAL_ZONE_ID" \
  --change-batch "file://$WORK_DIR/dns.json" >/dev/null
log "dns: $PAL_FQDN -> $IP"

# ---------------------------------------------------------------------------
# 3. ゲーム本体 (S3 キャッシュ復元 → steamcmd で差分パッチ)
# ---------------------------------------------------------------------------
APPID=2394010
mkdir -p "$PAL_DIR"

CACHE_HIT=0
if $AWS s3 cp "$S3/gamecache/palserver.tar.zst" - 2>/dev/null | zstd -d -q | tar -xf - -C "$PAL_DIR"; then
  CACHE_HIT=1
  log "game cache restored from S3"
else
  rm -rf "${PAL_DIR:?}"/* # 途中まで展開された残骸を消してフルインストールへ
  log "no game cache; full install via steamcmd (first boot takes 5-8 min)"
  notify "🔧 初回セットアップ中" "ゲーム本体をダウンロードしています (5〜8 分かかります)。" blue
fi

chown -R palworld:palworld "$PAL_HOME"
# +app_update はキャッシュありなら差分パッチのみで数十秒。
sudo -u palworld "$STEAMCMD" +force_install_dir "$PAL_DIR" +login anonymous \
  +app_update $APPID +quit >/dev/null

# PalServer.sh が要求する steamclient.so (64bit) を配置。
# steamcmd (deb 版) のブートストラップ先は ~/Steam。
sudo -u palworld mkdir -p /home/palworld/.steam/sdk64
for so in /home/palworld/Steam/linux64/steamclient.so \
          /home/palworld/.local/share/Steam/steamcmd/linux64/steamclient.so; do
  if [ -f "$so" ]; then
    sudo -u palworld cp "$so" /home/palworld/.steam/sdk64/steamclient.so
    break
  fi
done
if [ ! -f /home/palworld/.steam/sdk64/steamclient.so ]; then
  # 最終手段: Steamworks SDK Redist (appid 1007) から取得する。
  sudo -u palworld "$STEAMCMD" +login anonymous +app_update 1007 +quit >/dev/null || true
  sudo -u palworld cp "/home/palworld/Steam/steamapps/common/Steamworks SDK Redist/linux64/steamclient.so" \
    /home/palworld/.steam/sdk64/steamclient.so 2>/dev/null || true
fi

# buildid が変わっていたらキャッシュを更新 (アップロードは起動をブロックしないよう裏で)。
LOCAL_BUILD=$(grep -Po '"buildid"\s+"\K[0-9]+' "$PAL_DIR/steamapps/appmanifest_$APPID.acf" 2>/dev/null || echo 0)
REMOTE_BUILD=$($AWS s3 cp "$S3/gamecache/buildid.txt" - 2>/dev/null || echo 0)
if [ "$LOCAL_BUILD" != "$REMOTE_BUILD" ] && [ "$LOCAL_BUILD" != "0" ]; then
  log "game updated (build $REMOTE_BUILD -> $LOCAL_BUILD); refreshing cache in background"
  (
    tar -C "$PAL_DIR" -cf - . | zstd -3 -T0 -q > "$WORK_DIR/gamecache.tar.zst"
    $AWS s3 cp "$WORK_DIR/gamecache.tar.zst" "$S3/gamecache/palserver.tar.zst" --no-progress >/dev/null
    echo "$LOCAL_BUILD" | $AWS s3 cp - "$S3/gamecache/buildid.txt" >/dev/null
    rm -f "$WORK_DIR/gamecache.tar.zst"
  ) &
fi

# ---------------------------------------------------------------------------
# 4. セーブ復元 (排他ロック待ち + 検証 + フォールバックは pal-restore.sh 内)
# ---------------------------------------------------------------------------
/opt/palworld/bin/pal-restore.sh

# 以後この個体が正。ロックを取得し、途中で死んだら後任が 90 秒で引き継ぐ。
lock_write

# ---------------------------------------------------------------------------
# 5. PalWorldSettings.ini 生成 (設定はコード側が正。セーブには含めない)
# ---------------------------------------------------------------------------
ADMIN_PASS=$($AWS ssm get-parameter --name "/$PAL_PROJECT/server/admin_password" \
  --with-decryption --query Parameter.Value --output text)
SERVER_PASS=$($AWS ssm get-parameter --name "/$PAL_PROJECT/server/server_password" \
  --with-decryption --query Parameter.Value --output text)
[ "$SERVER_PASS" = "__EMPTY__" ] && SERVER_PASS=""

CONF_DIR="$PAL_DIR/Pal/Saved/Config/LinuxServer"
mkdir -p "$CONF_DIR"

# python ブロックが environ 経由で読むため export する。
export PAL_SERVER_NAME PAL_SERVER_DESC PAL_MAX_PLAYERS PAL_GAME_PORT PAL_EXTRA_SETTINGS
export ADMIN_PASS SERVER_PASS

# DefaultPalWorldSettings.ini (全キー入りの雛形) を正として上書き項目を注入する。
python3 - "$PAL_DIR/DefaultPalWorldSettings.ini" "$CONF_DIR/PalWorldSettings.ini" <<'PYEOF'
import re, sys, os

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    text = f.read()

m = re.search(r"OptionSettings=\((.*)\)", text)
opts = {}
if m:
    # value 内にカンマは出ない前提 (Palworld の ini はフラットな key=value 列)
    for kv in m.group(1).split(","):
        if "=" in kv:
            k, v = kv.split("=", 1)
            opts[k.strip()] = v.strip()

overrides = {
    "ServerName": '"' + os.environ["PAL_SERVER_NAME"] + '"',
    "ServerDescription": '"' + os.environ["PAL_SERVER_DESC"] + '"',
    "AdminPassword": '"' + os.environ["ADMIN_PASS"] + '"',
    "ServerPassword": '"' + os.environ["SERVER_PASS"] + '"',
    "ServerPlayerMaxNum": os.environ["PAL_MAX_PLAYERS"],
    "PublicPort": os.environ["PAL_GAME_PORT"],
    "RCONEnabled": "True",
    "RCONPort": "25575",
}
for kv in os.environ.get("PAL_EXTRA_SETTINGS", "").split(","):
    if "=" in kv:
        k, v = kv.split("=", 1)
        overrides[k.strip()] = v.strip()

opts.update(overrides)
body = ",".join(f"{k}={v}" for k, v in opts.items())
with open(dst, "w", encoding="utf-8") as f:
    f.write("[/Script/Pal.PalGameWorldSettings]\n")
    f.write(f"OptionSettings=({body})\n")
PYEOF
chown -R palworld:palworld "$PAL_DIR/Pal/Saved"

# ---------------------------------------------------------------------------
# 6. systemd ユニット配置 → 起動
# ---------------------------------------------------------------------------
for unit in /opt/palworld/systemd/*; do
  sed -e "s/@GAME_PORT@/$PAL_GAME_PORT/g" \
      -e "s/@MAX_PLAYERS@/$PAL_MAX_PLAYERS/g" \
      -e "s/@BACKUP_MIN@/$PAL_BACKUP_MINUTES/g" \
      "$unit" > "/etc/systemd/system/$(basename "$unit")"
done
systemctl daemon-reload
systemctl enable --now palworld.service pal-guardian.service pal-idle.service \
  pal-backup.timer pal-status.timer

# ---------------------------------------------------------------------------
# 7. 起動完了を待って通知
# ---------------------------------------------------------------------------
/opt/palworld/bin/pal-status.sh starting || true

READY=0
for _ in $(seq 1 60); do
  if rcon "Info" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 5
done

BOOT_SEC=$(( $(date -u +%s) - $(cat "$STATE_DIR/boot-epoch") ))
if [ "$READY" = "1" ]; then
  notify "🎮 サーバーが起動しました (${BOOT_SEC} 秒)" \
    "接続先: **$PAL_FQDN:$PAL_GAME_PORT**\n$([ -n "$SERVER_PASS" ] && echo "パスワード付きサーバーです。")\n${PAL_IDLE_MINUTES} 分無人で自動停止します。" green
  /opt/palworld/bin/pal-status.sh running || true
else
  notify "🚨 サーバーの起動確認に失敗しました" \
    "${BOOT_SEC} 秒待ちましたが RCON が応答しません。/pal status で確認してください。" red
fi

log "install done (ready=$READY, ${BOOT_SEC}s)"

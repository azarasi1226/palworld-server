#!/usr/bin/env bash
# インスタンス起動時のセットアップ本体 (user_data から exec される)。
# 流れ: OS 準備 → DNS 更新 → ゲーム本体復元 → セーブ復元 → 設定生成 → systemd 起動 → 起動通知
source /opt/palworld/lib/common.sh

date -u +%s > "$STATE_DIR/boot-epoch"
log "install start"

# --- 起動処理が失敗したときに課金を止める ------------------------------------
# ここで失敗すると、この個体を止められる者が誰もいない状態になる。
#   ・pal-guardian も pal-idle も、まだ起動していない (step 6 で起動する)
#   ・EC2 としては正常なので ASG も置き換えない
# 結果、ゲームが動いていないインスタンスが誰にも気づかれず課金され続ける
# (1 晩で ¥140、1 週間で ¥2,900)。そのため「失敗したら自分で desired=0 にする」
# ところまでを install.sh の責任に含める。
#
# 個別の exit ではなく trap を使うのは、set -e による想定外の中断も
# 同じ扱いにするため。step 6 で監視役が立ったら trap は外す (それ以降は
# 失敗してもサーバーは動いており、無人停止が効くため)。
on_install_failure() {
  local rc=$?
  [ "$rc" = "0" ] && return 0
  log "install failed (rc=$rc); setting desired=0 to stop billing"
  notify "🚨 起動に失敗したため停止します" \
    "セーブは S3 に保全されています。\`/pal start\` でやり直せます。\n繰り返す場合は \`/pal status\` とサーバーのログを確認してください。" red
  $AWS autoscaling set-desired-capacity \
    --auto-scaling-group-name "$PAL_PROJECT-server" --desired-capacity 0 2>/dev/null || true
}
trap on_install_failure EXIT

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

# 必要なコマンドは Ubuntu 24.04 の AMI に揃っているため、通常は apt を通らない。
# 欠けている時だけ入れる (AMI の内容が変わった場合の保険)。
# ここで apt を必ず実行していた頃は、実質何も入らないのに 10 秒以上かかっていた。
MISSING=""
for c in zstd curl jq python3; do
  command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
  log "installing missing packages:$MISSING"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq $MISSING >/dev/null
fi

# steamcmd はここでは入れない。キャッシュから復元する通常の起動では使わないため、
# 必要になった時点で ensure_steamcmd() が導入する (common.sh 参照)。

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
# 3. ゲーム本体を用意する
#
#    ここでは「動かせる状態にする」ことだけを行い、更新は一切しない。
#    更新は /pal update (pal-update.sh) が担当する。
#    起動のたびに更新を挟むと、更新失敗がそのまま起動失敗になり、
#    意図しないタイミングでバージョンが上がってしまうため分離している。
# ---------------------------------------------------------------------------
mkdir -p "$PAL_DIR"

# --- 展開する前にキャッシュが使えるか決める ---------------------------------
# Palworld は「セーブより古いゲーム」では起動できない。
#   Save data version mismatch. This data was created with a newer version.
# → LowLevelFatalError で即クラッシュし、systemd が再起動を繰り返すだけになる。
#
# この状況は /pal update の直後にキャッシュ更新が失敗した (または更新中に
# 回収された) 場合に起こる。展開してから気づくとセーブを退避・復元しながら
# 入れ替える必要が出るため、展開前に判定して使わない判断だけを下す。
# 判定の結果はクリーンインストール (= キャッシュが無いときと同じ経路) に合流する。
SAVE_BUILD=$($AWS s3api head-object --bucket "$PAL_BUCKET" --key "saves/latest.tar.zst" \
  --query 'Metadata."game-buildid"' --output text 2>/dev/null || echo 0)
CACHE_BUILD=$($AWS s3 cp "$S3/gamecache/buildid.txt" - 2>/dev/null || echo 0)
# メタデータ無し ("None") や取得失敗は 0 に寄せる。set -e 下で数値比較を
# 安全に行うため、ここで必ず数値にしておく。
case "$SAVE_BUILD" in '' | *[!0-9]*) SAVE_BUILD=0 ;; esac
case "$CACHE_BUILD" in '' | *[!0-9]*) CACHE_BUILD=0 ;; esac

# セーブの世代が分かっていて、キャッシュがそれより古い (or 不明) なら使わない。
# 不明 (0) も使わない側に倒す。余計にクリーンインストールするだけで済み、
# 逆に古いキャッシュを使うとクラッシュループになるため。
CACHE_USABLE=1
if [ "$SAVE_BUILD" -gt 0 ] && [ "$SAVE_BUILD" -gt "$CACHE_BUILD" ]; then
  log "cache is not new enough for the save (cache=$CACHE_BUILD save=$SAVE_BUILD); ignoring it"
  CACHE_USABLE=0
fi

if [ "$CACHE_USABLE" = "1" ] \
  && $AWS s3 cp "$S3/gamecache/palserver.tar.zst" - 2>/dev/null | zstd -d -q | tar -xf - -C "$PAL_DIR"; then
  log "game restored from S3 cache (buildid=$(buildid_local))"
else
  # キャッシュが無い / 壊れている / セーブに対して古い場合は steamcmd で取得する。
  rm -rf "${PAL_DIR:?}"/* # 途中まで展開された残骸を消す
  if [ "$CACHE_USABLE" = "0" ]; then
    log "installing via steamcmd (cache too old for the save)"
    notify "⬆️ ゲーム本体を更新します" \
      "セーブが新しいバージョンで作られているため、最新版を取得してから起動します（3〜5 分）。" yellow
  else
    log "no usable game cache; installing via steamcmd"
    notify "🔧 ゲーム本体を取得しています" "初回セットアップのためダウンロードしています (3〜5 分かかります)。" blue
  fi

  chown -R palworld:palworld "$PAL_HOME"
  run_steamcmd || log "steamcmd returned non-zero; verifying actual state"

  if [ ! -x "$PAL_DIR/PalServer.sh" ]; then
    log "FATAL: game files are missing after steamcmd"
    notify "🚨 ゲーム本体の取得に失敗しました" "Steam 側の一時障害の可能性があります。\n時間をおいて /pal start でやり直してください。" red
    exit 1
  fi
fi

# キャッシュから復元した場合も、中身が壊れていれば起動できない。
# 早い段階で気づけるよう、ここで実体を確認する。
if [ ! -x "$PAL_DIR/PalServer.sh" ]; then
  log "FATAL: PalServer.sh is missing after restoring the cache"
  notify "🚨 ゲーム本体が壊れています" "S3 のキャッシュが不完全な可能性があります。\ngamecache/ を削除してから /pal start でやり直してください。" red
  exit 1
fi

# 用意できたゲームが本当にセーブより新しいか、実体 (appmanifest) で最終確認する。
# 上の判定は buildid.txt という「申告」を見ているだけなので、ここで突き合わせる。
# 通常は成立しないが、成立した場合はクラッシュループにさせず理由を伝えて止める。
GAME_BUILD=$(buildid_local)
case "$GAME_BUILD" in '' | *[!0-9]*) GAME_BUILD=0 ;; esac
if [ "$SAVE_BUILD" -gt 0 ] && [ "$GAME_BUILD" -gt 0 ] && [ "$SAVE_BUILD" -gt "$GAME_BUILD" ]; then
  log "FATAL: game is older than the save (save=$SAVE_BUILD game=$GAME_BUILD)"
  notify "🚨 起動できません" \
    "セーブ (build $SAVE_BUILD) より新しいゲーム本体を取得できませんでした。\nSteam 側の障害の可能性があります。時間をおいて /pal start でやり直してください。" red
  exit 1
fi

chown -R palworld:palworld "$PAL_HOME"

# PalServer.sh が要求する steamclient.so (64bit) を配置。
#
# ★ 探索順が重要。先の 2 つはゲーム本体に同梱されており $PAL_DIR の中にあるため
#   S3 キャッシュにも含まれる = ダウンロード不要で必ず見つかる。
#   後の 2 つは steamcmd が作るディレクトリで、$PAL_DIR の外にあるので
#   キャッシュ復元だけの起動には存在しない。
#   以前は steamcmd 側しか見ていなかったため、毎回フォールバックの
#   app_update 1007 (103MB) が走り、起動が 63 秒延びていた。
sudo -u palworld mkdir -p /home/palworld/.steam/sdk64
for so in "$PAL_DIR/linux64/steamclient.so" \
          "$PAL_DIR/Pal/Binaries/Linux/steamclient.so" \
          /home/palworld/Steam/linux64/steamclient.so \
          /home/palworld/.local/share/Steam/steamcmd/linux64/steamclient.so; do
  if [ -f "$so" ]; then
    sudo -u palworld cp "$so" /home/palworld/.steam/sdk64/steamclient.so
    break
  fi
done
if [ ! -f /home/palworld/.steam/sdk64/steamclient.so ]; then
  # 最終手段: Steamworks SDK Redist (appid 1007) から取得する。
  # ここへ来るのはゲーム本体が壊れている場合だけなので、steamcmd の導入込みで許容する。
  log "steamclient.so not found in the game files; falling back to the Steamworks SDK"
  ensure_steamcmd \
    && sudo -u palworld HOME=/home/palworld "$STEAMCMD" +login anonymous +app_update 1007 +quit >/dev/null || true
  sudo -u palworld cp "/home/palworld/Steam/steamapps/common/Steamworks SDK Redist/linux64/steamclient.so" \
    /home/palworld/.steam/sdk64/steamclient.so 2>/dev/null || true
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
export ADMIN_PASS SERVER_PASS PAL_CROSSPLAY
export PUBLIC_IP="$IP"

# DefaultPalWorldSettings.ini (全キー入りの雛形) を正として上書き項目を注入する。
python3 - "$PAL_DIR/DefaultPalWorldSettings.ini" "$CONF_DIR/PalWorldSettings.ini" <<'PYEOF'
import re, sys, os

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    text = f.read()

m = re.search(r"OptionSettings=\((.*)\)", text)
opts = {}
if m:
    # 括弧内のカンマでは分割しない。CrossplayPlatforms=(Steam,Xbox,PS5,Mac) のような
    # 値があるため、単純な split(",") では設定が壊れる。
    for kv in re.split(r",(?![^()]*\))", m.group(1)):
        if "=" in kv:
            k, v = kv.split("=", 1)
            opts[k.strip()] = v.strip()

overrides = {
    "ServerName": '"' + os.environ["PAL_SERVER_NAME"] + '"',
    "ServerDescription": '"' + os.environ["PAL_SERVER_DESC"] + '"',
    "AdminPassword": '"' + os.environ["ADMIN_PASS"] + '"',
    "ServerPassword": '"' + os.environ["SERVER_PASS"] + '"',
    "ServerPlayerMaxNum": os.environ["PAL_MAX_PLAYERS"],
    "PublicIP": '"' + os.environ["PUBLIC_IP"] + '"',  # コミュニティ一覧への申告用
    "PublicPort": os.environ["PAL_GAME_PORT"],
    "RCONEnabled": "True",
    "RCONPort": "25575",
    # コンソール勢 (PS5/Xbox) の参加に必須。欠けたプラットフォームは接続不可になる
    "CrossplayPlatforms": "(" + os.environ.get("PAL_CROSSPLAY", "Steam,Xbox,PS5,Mac") + ")",
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
# -publiclobby: コミュニティサーバー一覧への掲載。PS5/Xbox は一覧経由でしか
# 参加できないため、コンソール勢がいる場合は必須。
PUBLIC_LOBBY_FLAG=""
[ "${PAL_PUBLIC_LOBBY:-false}" = "true" ] && PUBLIC_LOBBY_FLAG="-publiclobby"

for unit in /opt/palworld/systemd/*; do
  sed -e "s/@GAME_PORT@/$PAL_GAME_PORT/g" \
      -e "s/@MAX_PLAYERS@/$PAL_MAX_PLAYERS/g" \
      -e "s/@BACKUP_MIN@/$PAL_BACKUP_MINUTES/g" \
      -e "s/@PUBLIC_LOBBY@/$PUBLIC_LOBBY_FLAG/g" \
      "$unit" > "/etc/systemd/system/$(basename "$unit")"
done
systemctl daemon-reload
systemctl enable --now palworld.service pal-guardian.service pal-idle.service \
  pal-backup.timer pal-status.timer

# 監視役 (guardian / idle) が立ったので、以降は失敗しても放置されない。
# ここで trap を外さないと、起動後の些細な失敗 (通知の送信エラー等) で
# 正常に動いているサーバーを止めてしまう。
trap - EXIT

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
  # ここに来たらゲームが一度も立ち上がっていない (クラッシュループ等)。
  #
  # 停止まで行うのは、この時点なら「遊んでいる人を蹴る」心配が無いため。
  # 接続できた人が一人もいないことが確定している (RCON が一度も応答していない)。
  # 放置すると、無人判定は RCON 不応答では成立しないため誰も止められず、
  # ゲームが動いていないインスタンスの課金だけが続く。
  #
  # desired=0 にすれば ASG の終了指示 → guardian → 安全停止と通常の経路を通り、
  # ロック解放もログ退避も行われる。ここで独自の停止処理は書かない。
  log "server never became ready in ${BOOT_SEC}s; setting desired=0 to stop billing"
  notify "🚨 サーバーの起動確認に失敗しました" \
    "${BOOT_SEC} 秒待ちましたが応答がありません。課金を止めるため停止します。\nセーブは S3 に保全されています。\`/pal start\` でやり直せます。\n繰り返す場合はサーバーのログを確認してください。" red
  $AWS autoscaling set-desired-capacity \
    --auto-scaling-group-name "$PAL_PROJECT-server" --desired-capacity 0 2>/dev/null || true
fi

log "install done (ready=$READY, ${BOOT_SEC}s)"

# ---------------------------------------------------------------------------
# 8. 後処理 (キャッシュ保存 / 更新の有無を通知)
#
#    数分かかる処理なので install.sh の完了を待たせない。
#    ただし `&` で流すと cloud-init のサービス終了時に cgroup ごと
#    後始末されて完走しない恐れがあるため、独立したユニットとして起動する。
# ---------------------------------------------------------------------------
if ! systemd-run --unit=pal-post-boot --collect --quiet \
  /opt/palworld/bin/pal-post-boot.sh 2>/dev/null; then
  log "WARN: systemd-run failed; running post-boot in the background instead"
  /opt/palworld/bin/pal-post-boot.sh &
fi

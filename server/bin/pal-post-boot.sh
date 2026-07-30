#!/usr/bin/env bash
# 起動後の後処理をまとめて行う (install.sh から systemd-run で切り離して起動)。
#
# install.sh の中で `&` で流すと、cloud-init のサービスが完了した時点で
# systemd に cgroup ごと後始末され、数分かかる処理が完走しない恐れがある。
# 独立したユニットとして起動することでその巻き添えを防ぐ。
#
#   1. ゲーム本体のキャッシュを S3 へ保存する (次回起動を速くするため)
#   2. アップデートの有無を Discord へ知らせる (適用はしない)
source /opt/palworld/lib/common.sh

LOCAL=$(buildid_local)
if [ "$LOCAL" = "0" ]; then
  log "post-boot: buildid unknown; skipping"
  exit 0
fi

# --- 1. キャッシュの保存 ----------------------------------------------------
REMOTE=$($AWS s3 cp "$S3/gamecache/buildid.txt" - 2>/dev/null || echo 0)
if [ "$LOCAL" != "$REMOTE" ]; then
  log "post-boot: refreshing game cache (S3=$REMOTE local=$LOCAL)"
  upload_game_cache "$LOCAL" || true
else
  log "post-boot: game cache is current (build $LOCAL)"
fi

# --- 2. 更新の有無を通知 (適用はしない) -------------------------------------
# 起動処理では意図的に更新しないため、古いまま放置されないよう知らせる。
# Steam への問い合わせだけでダウンロードは発生しない。
LATEST=$(buildid_latest)
if [ "$LATEST" = "0" ]; then
  log "post-boot: update check skipped (could not reach Steam)"
elif [ "$LATEST" != "$LOCAL" ]; then
  log "post-boot: update available ($LOCAL -> $LATEST)"
  notify "🆕 アップデートがあります" \
    "現在: build $LOCAL\n最新: build $LATEST\n\n遊び終わったら \`/pal update\` で適用できます（2〜4 分）。\n※ 接続者がいる間は実行できません。" yellow
else
  log "post-boot: game is up to date (build $LOCAL)"
fi

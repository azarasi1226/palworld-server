#!/usr/bin/env bash
# 整合性チェック付き原子的バックアップ (DESIGN.md 層 1 / 層 4)。
#
#   pal-backup.sh            定期実行 (timer)。1 時間ごとに archive/ へも複製
#   pal-backup.sh --final    停止シーケンス用。サーバー停止済みでも動く
#
# 方針: 「良いバックアップを壊れたデータで上書きする」ことだけは絶対にしない。
# 検証に落ちたら latest には触らず quarantine へ退避して警告する。
source /opt/palworld/lib/common.sh

FINAL=0
[ "${1:-}" = "--final" ] && FINAL=1

# 定期 timer と緊急停止の同時実行を防ぐ。緊急側 (--final) は先行の定期実行を待つ。
exec 9>"$STATE_DIR/backup.flock"
if ! flock -w 60 9; then
  log "another backup is running and did not finish in 60s"
  exit 1
fi

# 前回実行の成果物を消しておく。検証失敗時の quarantine 退避が
# 古い tar を掴まないようにするため。
rm -f "$WORK_DIR/backup.tar.zst"

# ---------------------------------------------------------------------------
# 1. RCON Save でメモリ上のワールドをディスクへフラッシュ
# ---------------------------------------------------------------------------
if systemctl is-active --quiet palworld; then
  if rcon "Save"; then
    sleep 3 # 書き込み完了待ち
  else
    log "WARN: rcon Save failed; using on-disk state (autosave up to 30s old)"
  fi
fi

if [ ! -d "$SAVE_DIR" ]; then
  log "no save directory yet (server has not created a world); skipping"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. スナップショットコピー
#    ゲームのオートセーブと tar が重なって不整合な断面を固めないため、
#    先にローカルコピーしてからコピー側をアーカイブする。
# ---------------------------------------------------------------------------
SNAP="$WORK_DIR/snapshot"
rm -rf "$SNAP"
cp -a "$SAVE_DIR" "$SNAP"

LEVEL_SAV=$(find "$SNAP" -name "Level.sav" | head -n 1)

# ---------------------------------------------------------------------------
# 3. 整合性チェック
# ---------------------------------------------------------------------------
fail_quarantine() {
  local reason="$1" ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  log "INTEGRITY FAIL: $reason"
  if [ -f "$WORK_DIR/backup.tar.zst" ]; then
    $AWS s3 cp "$WORK_DIR/backup.tar.zst" "$S3/saves/quarantine/$ts.tar.zst" --no-progress >/dev/null || true
  fi
  notify "🚨 バックアップの整合性チェックに失敗" \
    "理由: $reason\nlatest は更新していません (前回の正常なバックアップを温存)。\n疑わしいデータは saves/quarantine/$ts.tar.zst に隔離しました。" red
  exit 1
}

# 前回バックアップの Level.sav サイズ (S3 メタデータに記録している)。
# 取れない = 初回 → ブートストラップモード (閾値を緩和)。
PREV_SIZE=$($AWS s3api head-object --bucket "$PAL_BUCKET" --key "saves/latest.tar.zst" \
  --query 'Metadata."level-sav-size"' --output text 2>/dev/null || echo "None")

if [ -z "$LEVEL_SAV" ]; then
  fail_quarantine "Level.sav が存在しない"
fi

SIZE=$(stat -c %s "$LEVEL_SAV")

# 絶対下限は「空・切り詰めの検出」だけが目的なので 4KB に留める。
# 新規ワールド直後の Level.sav は 15KB 程度しかない (実測)。
# 破損検出の本命は下の前回比チェック。
[ "$SIZE" -ge 4096 ] || fail_quarantine "Level.sav が小さすぎる (${SIZE}B < 4KB)"

if [ "$PREV_SIZE" = "None" ] || [ -z "$PREV_SIZE" ]; then
  log "bootstrap mode: first backup (Level.sav ${SIZE}B)"
elif [ "$SIZE" -lt $(( PREV_SIZE / 2 )) ]; then
  fail_quarantine "Level.sav が前回の 50% 未満に縮んだ (${SIZE}B < ${PREV_SIZE}B/2)。破損か初期化の疑い"
fi

# ---------------------------------------------------------------------------
# 4. アーカイブ作成 + 検証
# ---------------------------------------------------------------------------
tar -C "$SNAP" -cf - . | zstd -3 -T0 -q -o "$WORK_DIR/backup.tar.zst" --force
zstd -d -q --stdout "$WORK_DIR/backup.tar.zst" | tar -tf - >/dev/null \
  || fail_quarantine "作成した tar が読めない"

# ---------------------------------------------------------------------------
# 5. 原子的 PUT (単一オブジェクト上書き。旧世代はバージョニングが保持)
# ---------------------------------------------------------------------------
$AWS s3 cp "$WORK_DIR/backup.tar.zst" "$S3/saves/latest.tar.zst" \
  --metadata "level-sav-size=$SIZE,game-buildid=$(buildid_local)" --no-progress >/dev/null

date -u +%s > "$STATE_DIR/last-backup-epoch"
log "backup ok: Level.sav=${SIZE}B archive=$(stat -c %s "$WORK_DIR/backup.tar.zst")B"

# ---------------------------------------------------------------------------
# 6. 1 時間ごとの世代アーカイブ (30 日保持のロングテール。層 1 参照)
# ---------------------------------------------------------------------------
if [ "$FINAL" = "0" ]; then
  NOW=$(date -u +%s)
  LAST_ARCHIVE=$(cat "$STATE_DIR/last-archive-epoch" 2>/dev/null || echo 0)
  if [ $(( NOW - LAST_ARCHIVE )) -ge 3600 ]; then
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    $AWS s3 cp "$S3/saves/latest.tar.zst" "$S3/saves/archive/$TS.tar.zst" --no-progress >/dev/null
    echo "$NOW" > "$STATE_DIR/last-archive-epoch"
    log "hourly archive: $TS.tar.zst"
  fi
fi

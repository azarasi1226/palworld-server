#!/usr/bin/env bash
# セーブ復元 (DESIGN.md 層 5)。install.sh からサーバー起動前に呼ばれる。
#
# フォールバック順:
#   1. saves/latest.tar.zst (現行)
#   2. latest のバージョン履歴を新しい順
#   3. saves/archive/ の最新
# latest が存在しない場合は初回起動 = 新規ワールド。
# ただし archive 等があるのに latest だけ無い場合は異常なので起動を中断する。
source /opt/palworld/lib/common.sh

# 前任インスタンスがセーブをアップロードし終えるまで復元を始めない (排他制御)。
lock_wait

CAND="$WORK_DIR/restore.tar.zst"
EXTRACT="$WORK_DIR/restore-extract"

# 展開して Level.sav の存在とサイズを検証。通れば 0。
try_candidate() {
  local desc="$1"
  rm -rf "$EXTRACT"
  mkdir -p "$EXTRACT"
  if ! zstd -d -q --stdout "$CAND" | tar -xf - -C "$EXTRACT" 2>/dev/null; then
    log "candidate rejected ($desc): tar/zstd unreadable"
    return 1
  fi
  local lv size
  lv=$(find "$EXTRACT" -name "Level.sav" | head -n 1)
  if [ -z "$lv" ]; then
    log "candidate rejected ($desc): no Level.sav"
    return 1
  fi
  size=$(stat -c %s "$lv")
  if [ "$size" -lt 102400 ]; then
    log "candidate rejected ($desc): Level.sav too small (${size}B)"
    return 1
  fi
  log "restore candidate accepted ($desc): Level.sav=${size}B"
  return 0
}

install_save() {
  mkdir -p "$(dirname "$SAVE_DIR")"
  rm -rf "$SAVE_DIR"
  mv "$EXTRACT" "$SAVE_DIR"
  chown -R palworld:palworld "$SAVE_DIR"
  log "save restored into $SAVE_DIR"
}

# --- 1. 現行の latest ------------------------------------------------------
if $AWS s3 cp "$S3/saves/latest.tar.zst" "$CAND" --no-progress >/dev/null 2>&1; then
  if try_candidate "latest (current)"; then
    install_save
    exit 0
  fi
  notify "⚠️ latest のセーブが破損しています" "バージョン履歴からのフォールバックを試みます。" yellow

  # --- 2. バージョン履歴を新しい順 ----------------------------------------
  VERSIONS=$($AWS s3api list-object-versions --bucket "$PAL_BUCKET" \
    --prefix "saves/latest.tar.zst" \
    --query "sort_by(Versions,&LastModified)[::-1].[VersionId,IsLatest]" --output text)

  while read -r vid is_latest; do
    [ "$is_latest" = "True" ] && continue # 現行は検証済みなので飛ばす
    log "trying version $vid"
    $AWS s3api get-object --bucket "$PAL_BUCKET" --key "saves/latest.tar.zst" \
      --version-id "$vid" "$CAND" >/dev/null 2>&1 || continue
    if try_candidate "version $vid"; then
      install_save
      notify "✅ 過去バージョンから復元しました" "version: $vid\n最新のセーブは破損していたため 1 世代以上巻き戻っています。" yellow
      exit 0
    fi
  done <<< "$VERSIONS"

  # --- 3. archive の最新 ---------------------------------------------------
  NEWEST_ARCHIVE=$($AWS s3api list-objects-v2 --bucket "$PAL_BUCKET" \
    --prefix "saves/archive/" \
    --query "sort_by(Contents,&LastModified)[-1].Key" --output text 2>/dev/null || echo "None")
  if [ "$NEWEST_ARCHIVE" != "None" ] && [ -n "$NEWEST_ARCHIVE" ]; then
    log "trying archive $NEWEST_ARCHIVE"
    if $AWS s3 cp "$S3/$NEWEST_ARCHIVE" "$CAND" --no-progress >/dev/null 2>&1 \
        && try_candidate "archive $NEWEST_ARCHIVE"; then
      install_save
      notify "✅ 世代アーカイブから復元しました" "$NEWEST_ARCHIVE\n最大 1 時間程度巻き戻っています。" yellow
      exit 0
    fi
  fi

  # 全滅。新規ワールドで上書き起動してはいけない (次のバックアップで正を潰すため)。
  notify "🚨 復元に失敗しました" \
    "latest・バージョン履歴・アーカイブのすべてが検証を通りませんでした。\nサーバーは起動しません。saves/ を手動で確認してください。" red
  exit 1
fi

# --- latest が存在しない ---------------------------------------------------
OTHERS=$($AWS s3api list-objects-v2 --bucket "$PAL_BUCKET" --prefix "saves/" \
  --max-items 1 --query "Contents[0].Key" --output text 2>/dev/null || echo "None")
if [ "$OTHERS" != "None" ] && [ -n "$OTHERS" ]; then
  # archive や quarantine があるのに latest だけ無い = 誰かが消した等の異常。
  notify "🚨 セーブ状態が異常です" \
    "saves/ にデータがあるのに latest.tar.zst がありません。\n新規ワールドで上書きしないため、サーバーは起動しません。" red
  exit 1
fi

log "no existing save: first boot, starting a new world"
exit 0

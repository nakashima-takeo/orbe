#!/usr/bin/env bash
# Orbe Dev を quit → /Applications/Orbe Dev.app を置換 → 再起動する破壊フェーズ。
# install.sh から呼ばれる: Orbe Dev の外なら前景で、中からなら nohup で本体の生死から切り離して。
# 本番の /Applications/Orbe.app には一切触れない（dev は別 identity のアプリとして共存する）。
set -euo pipefail

DEST="/Applications/Orbe Dev.app"
DEV_BUNDLE_ID="dev.orbe.app.dev"
SRC="$1"          # 据える新ビルド（build/Orbe.app）
OLD_PID="${2:-}"  # 入れ替え対象の Orbe Dev pid（外部実行時は空）

echo "==> 起動中の Orbe Dev を終了"
# quit 対象は bundle ID で指す。アプリ名指定は ① 名前解決なので本番の Orbe を落としに行く
# ② 対象不在時に「どこ？」の選択ダイアログを出しうる。存在しない bundle ID への tell は
# ダイアログ無しの syntax error で終わるだけなので、初回インストール時も静かに素通りする。
osascript -e "tell application id \"$DEV_BUNDLE_ID\" to quit" 2>/dev/null || true
if [ -n "$OLD_PID" ]; then
  # 本体が実際に消えるまで待ってから置換する（置換途中のバンドルを掴まれるのを避ける）。
  for _ in $(seq 1 100); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.1; done
fi
pkill -f "$DEST/Contents/MacOS/Orbe" 2>/dev/null || true
sleep 0.5

echo "==> インストール: $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> 起動"
open "$DEST"
echo "==> 完了"

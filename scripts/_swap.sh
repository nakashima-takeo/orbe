#!/usr/bin/env bash
# Orbe を quit → /Applications/Orbe.app を置換 → 再起動する破壊フェーズ。
# install.sh から呼ばれる: Orbe の外なら前景で、中からなら nohup で本体の生死から切り離して。
set -euo pipefail

DEST="/Applications/Orbe.app"
SRC="$1"          # 据える新ビルド（build/Orbe.app）
OLD_PID="${2:-}"  # 入れ替え対象の Orbe pid（外部実行時は空）

echo "==> 起動中の Orbe を終了"
osascript -e 'tell application "Orbe" to quit' 2>/dev/null || true
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

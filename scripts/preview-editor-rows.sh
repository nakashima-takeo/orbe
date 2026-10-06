#!/usr/bin/env bash
# 区画の追従を人が判定する試しの場（テスト側。製品には何も足さない）。ミニマップを出さない 200KB の文書に、区画（PR の
# スレッドに近い試しの view——枠・折り返す文・入力欄）と文書に無い行を差し込んだエディターの窓を画面に出し、前面に置く。
# 見るのは、区画の枠が本文の行から離れて見えないか・窓の幅を変えたとき区画の高さが中身に合うか・区画の入力欄に日本語を
# 打てるか。画面のロックを外して回す。通常の swift test と CI では skip（EditorRowsTrialTests）。
#
#   scripts/preview-editor-rows.sh [秒数]       → 窓を秒数（既定 180）置き、人がトラックパッドで速く・はじいて・端で
#                                                 弾ませてスクロールする
#   scripts/preview-editor-rows.sh --synthetic  → 合成の速いスクロール（ドラッグ・はじき・端での弾み）を繰り返し流す
#                                                 （何度でも同じ動きで見返せる）
set -euo pipefail
cd "$(dirname "$0")/.."

mode=interactive
seconds=180
case "${1:-}" in
  --synthetic) mode=synthetic ;;
  "") ;;
  *) seconds="$1" ;;
esac

ORBE_EDITOR_ROWS_TRIAL=1 ORBE_EDITOR_ROWS_MODE="$mode" ORBE_EDITOR_ROWS_SECONDS="$seconds" \
  swift test --filter "OrbeTests.EditorRowsTrialTests" 2>&1 \
  | grep -E "passed|failed|error:" || true

#!/usr/bin/env bash
# 区画と並列の 2 面を人が判定する試しの場（テスト側。製品には何も足さない）。既定の型は、ミニマップを出さない文書に、試しの
# スレッドの区画（見本の PR のスレッドの構成——枠・影・頭・アバター・折り返す本文とインラインコード・関連コミット・返信の
# 入力欄とボタン）と文書に無い行を差し込んだエディターの窓を画面に出し、前面に置く。画面のロックを外して回す。通常の swift test と CI では skip
# （EditorRowsTrialTests）。
#
#   scripts/preview-editor-rows.sh [秒数]       → 200KB の文書の窓を秒数（既定 180）置き、人がトラックパッドとキーボードで
#                                                 触る（速く・はじいて・端で弾ませるスクロール、窓の幅、入力欄の日本語と
#                                                 候補窓、区画の文の選択とコピー、ボタンのホバーと押下）
#   scripts/preview-editor-rows.sh --side [秒数] → 並列の diff の 2 面（スクロールを共にする）を秒数（既定 180）置き、人が
#                                                 どちらの面でもトラックパッドで速く・はじいて・端で弾ませて動かし、窓の下の
#                                                 「並びを置き直す」で両面の並びを同じ周で置き直す
#   scripts/preview-editor-rows.sh --synthetic  → 合成のはじき（6000pt/s）と端の弾みを流しながら、窓が画面に出したコマを
#                                                 受けて（ScreenCaptureKit。画面収録の許可が要る）区画の枠線と上下の行の
#                                                 距離がどのコマでも同じかを確かめ、連番の PNG と並べた 1 枚を
#                                                 .preview/flows/rows-trial/ に書き出す
set -euo pipefail
cd "$(dirname "$0")/.."

mode=interactive
seconds=180
case "${1:-}" in
  --synthetic) mode=synthetic ;;
  --side)
    mode=side
    seconds="${2:-$seconds}"
    ;;
  "") ;;
  *) seconds="$1" ;;
esac

ORBE_EDITOR_ROWS_TRIAL=1 ORBE_EDITOR_ROWS_MODE="$mode" ORBE_EDITOR_ROWS_SECONDS="$seconds" \
  swift test --filter "OrbeTests.EditorRowsTrialTests" 2>&1 \
  | grep -E "rows-trial|passed|failed|error:" || true

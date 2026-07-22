#!/usr/bin/env bash
# レイヤー①（見た目）の確認: 全 story を PNG 化して開く。.app 起動も Peekaboo も不要。
# 各部品/画面の #Preview を Xcode の Preview キャンバスでライブに見る手もある（こちらは静止一覧）。
set -euo pipefail
cd "$(dirname "$0")/.."

ORBE_GALLERY=1 swift test --filter DesignGallerySnapshotTests 2>&1 \
  | grep -E "\[gallery\] wrote|passed|failed|error:" || true

open .preview/gallery

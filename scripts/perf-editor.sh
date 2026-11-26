#!/usr/bin/env bash
# エディターの性能を測る: release のテスト用ビルドを作り、EditorTypingPerfTests（打鍵 1 回とライブ変換の main の仕事、
# 64KB・1MB・8MB の打鍵 1 回で文書と配り先がする main の仕事）と EditorSyntaxPerfTests（構文の崩れる打鍵の裏の重さ、
# 開いてから全体の色が揃うまで）と ProjectSearchArrowPerfTests（検索結果の ↑↓ を押し続けたときに開く回数と、開かない
# キーの main の仕事・仮の文書を入れ替える開きの記録）と EditorDiffPerfTests（1MB の大きな書き換えで、裏の行差分の時間と、
# 並びを作って面に置く main の仕事。1MB の作業ツリー diff の中の打鍵 1 回の main の仕事）と FileTreePerfTests（絞り込みの
# 名前 5 万件に対する照合と木の組み立て 1 回の裏の重さ、結果を受け取ってからツリーの配置が終わるまでと欄への打鍵 1 回の
# main の仕事、子のフォルダ 2,000 個のフォルダを開く 1 回と、面が見え直したときの取り直し 1 回の main の仕事）を回して PERF の
# 行を出す。目標は各テストの説明にあり、関門はアサートが持つ。行差分の時間の目安は、diff の上限（`EditorDiff.hunkLimit`）の説明にある。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG 2>&1 \
  | grep -E "error:|Build complete" | tail -3
xctest=$(xcrun --find xctest)

ORBE_EDITOR_PERF=1 "$xctest" \
  -XCTest OrbeTests.EditorTypingPerfTests,OrbeTests.EditorSyntaxPerfTests,OrbeTests.ProjectSearchArrowPerfTests,OrbeTests.EditorDiffPerfTests,OrbeTests.FileTreePerfTests \
  .build/release/OrbeTests.xctest 2>&1 \
  | { grep -E "^PERF|error:|failed" || true; }

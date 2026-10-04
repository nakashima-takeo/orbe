#!/usr/bin/env bash
# エディターの性能を測る: release のテスト用ビルドを作り、EditorTypingPerfTests（打鍵 1 回とライブ変換の main の仕事、
# 64KB・1MB・8MB の打鍵 1 回で文書と配り先がする main の仕事）と EditorSyntaxPerfTests（構文の崩れる打鍵の裏の重さ、
# 開いてから全体の色が揃うまで）と ProjectSearchArrowPerfTests（検索結果の ↑↓ を押し続けたときに開く回数と、開かない
# キーの main の仕事・仮のタブを入れ替える開きの記録）を回して PERF の行を出す。目標は docs/testing/test-architecture.md。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG 2>&1 \
  | grep -E "error:|Build complete" | tail -3
xctest=$(xcrun --find xctest)

ORBE_EDITOR_PERF=1 "$xctest" \
  -XCTest OrbeTests.EditorTypingPerfTests,OrbeTests.EditorSyntaxPerfTests,OrbeTests.ProjectSearchArrowPerfTests \
  .build/release/OrbeTests.xctest 2>&1 \
  | { grep -E "^PERF|error:|failed" || true; }

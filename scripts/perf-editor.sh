#!/usr/bin/env bash
# エディターの性能を測る: release のテスト用ビルドを作り、EditorScrollPerfTests（1MB・200KB）を回して PERF の行を出す。
# 環境変数は .app を Finder から起こしたときと同じ 13 個に絞る——テキストエンジン（STTextView）は描画の経路で環境変数を
# 読み直すので、環境の大きい shell からそのまま測ると実アプリより遅く出る（`swift test` も十数個足すので、xctest を
# 直に起こす）。目標は docs/testing/test-architecture.md。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG 2>&1 \
  | grep -E "error:|Build complete" | tail -3
xctest=$(xcrun --find xctest)

env -i \
  HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" SHELL="${SHELL:-/bin/zsh}" \
  TMPDIR="${TMPDIR:-/tmp/}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  __CF_USER_TEXT_ENCODING="${__CF_USER_TEXT_ENCODING:-0x1F5:0x1:0xE}" \
  SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" OSLogRateLimit=64 COMMAND_MODE=unix2003 \
  __CFBundleIdentifier=dev.orbe.app.dev XPC_SERVICE_NAME=0 XPC_FLAGS=0x0 \
  ORBE_EDITOR_PERF=1 \
  "$xctest" -XCTest OrbeTests.EditorScrollPerfTests .build/release/OrbeTests.xctest 2>&1 \
  | grep -E "^PERF|error:|failed" || true

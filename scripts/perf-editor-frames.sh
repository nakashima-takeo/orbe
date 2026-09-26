#!/usr/bin/env bash
# 新しいテキスト面（Metal）のコマを測る——実装の関門。release のテスト用ビルドを作り、FramePerfTests（1MB・200KB で、
# 窓を出さず画面外に 120Hz で描き、合成した指の出来事を約 5.7ms ごとに流す。main への負荷の有り無し・詰まった面の隣・
# 止まっている間の起床）を回して PERF-FRAMES の行を出す。環境変数は .app を Finder から起こしたときと同じに絞る
# （perf-editor.sh と同じ理由）。目標は docs/testing/test-architecture.md。
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
  "$xctest" -XCTest OrbeEditorEngineTests.FramePerfTests .build/release/OrbeEditorEngineTests.xctest 2>&1 \
  | { grep -E "^PERF-FRAMES|error:|failed|passed \(" || true; }

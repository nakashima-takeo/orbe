#!/usr/bin/env bash
# テキスト面（Metal）のコマと打鍵を測る——実装の関門。release のテスト用ビルドを作り、FramePerfTests（1MB・200KB で、窓を
# 出さず画面外に 120Hz で描き、合成した指の出来事を約 5.7ms ごとに、合成の打鍵を 100ms と 33ms の間隔で流す。main への
# 負荷の有り無し・詰まった面の隣・止まっている間の起床・長い行・差し込みの多い面）を回して PERF-FRAMES の行を出す。目標は
# docs/testing/test-architecture.md。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG 2>&1 \
  | grep -E "error:|Build complete" | tail -3
xctest=$(xcrun --find xctest)

ORBE_EDITOR_PERF=1 "$xctest" -XCTest OrbeEditorEngineTests.FramePerfTests \
  .build/release/OrbeEditorEngineTests.xctest 2>&1 \
  | { grep -E "^PERF-FRAMES|error:|failed|passed \(" || true; }

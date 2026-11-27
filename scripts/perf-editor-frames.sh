#!/usr/bin/env bash
# テキスト面（Metal）のコマと打鍵を測る——実装の関門。release のテスト用ビルドを作り、FramePerfTests（1MB・200KB で、窓を
# 出さず画面外に 120Hz で描き、合成した指の出来事を約 5.7ms ごとに、合成の打鍵を 100ms と 33ms の間隔で流す。main への
# 負荷の有り無し・詰まった面の隣・止まっている間の起床・長い行・差し込みの多い面）を回して PERF-FRAMES の行を出す。関門は
# FramePerfTests の説明とアサートが持つ。LineShaperPerfTests（行の組版を直に呼び、ASCII の Swift・日本語の Markdown・
# 和文の後ろに記号がある文を組む時間）も回して PERF-SHAPE の行を出す（関門は持たない）。LineWrapPerfTests（行の折り返しを
# 直に呼び、1 万字の行・上限の前後の文書で幅を変えた 1 回・字ごとの表が空のときを測る）も回して PERF-WRAP の行を出す（関門は
# LineWrapPerfTests の説明とアサートが持つ）。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG 2>&1 \
  | grep -E "error:|Build complete" | tail -3
xctest=$(xcrun --find xctest)

ORBE_EDITOR_PERF=1 "$xctest" \
  -XCTest OrbeEditorEngineTests.FramePerfTests,OrbeEditorEngineTests.LineShaperPerfTests,OrbeEditorEngineTests.LineWrapPerfTests \
  .build/release/OrbeEditorEngineTests.xctest 2>&1 \
  | { grep -E "^PERF-FRAMES|^PERF-SHAPE|^PERF-WRAP|error:|failed|passed \(" || true; }

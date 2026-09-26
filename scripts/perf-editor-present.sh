#!/usr/bin/env bash
# 画面に出す計測（朝の場で回し、その結果を正とする。関門にはしない）。窓を画面に出すので、画面のロックを外し、スリープ
# させずに回す（アプリは activate しない）。release のテスト用ビルドで EditorPresentPerfTests を xctrace（Animation
# Hitches）の下で起こし、次を並べる:
#   - 新しい面（Metal）: 1MB に合成の指の出来事を約 5.7ms ごとに流す。記録係の要約（出来事→present・落ちたコマ）と hitches
#   - 今の面（STTextView）: 非公開の _automateLiveScroll で本物のスクロールの経路を回す。hitches
# 目標は docs/testing/test-architecture.md。
#
#   scripts/perf-editor-present.sh [out_dir]
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-.preview/perf-present}"
mkdir -p "$out"

swift build --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG 2>&1 \
  | grep -E "error:|Build complete" | tail -3
xctest=$(xcrun --find xctest)

for surface in Metal Current; do
  trace="$out/$surface.trace"
  rm -rf "$trace"
  began=$(date '+%Y-%m-%d %H:%M:%S')
  xcrun xctrace record --template 'Animation Hitches' --time-limit 40s --output "$trace" \
    --env ORBE_EDITOR_PRESENT=1 --target-stdout - --launch -- \
    "$xctest" -XCTest "OrbeTests.EditorPresentPerfTests/test${surface}Surface" \
    .build/release/OrbeTests.xctest > "$out/$surface.stdout" 2>&1 || true
  echo "== $surface"
  grep -E "^PRESENT|error:|failed" "$out/$surface.stdout" || true
  if [[ $surface == Metal ]]; then
    log show --start "$began" --predicate 'category == "editor-frames"' --style compact \
      | grep -E "gesture" || echo "（記録係の要約が見つからない）"
  fi
  python3 - "$trace" "$out/$surface.stdout" <<'PY'
# xctrace の hitches 表から、計測の区間（PRESENT start〜end）のコマ落ちの時間の割合を出す。
import re, subprocess, sys, xml.etree.ElementTree as ET

trace, stdout = sys.argv[1], sys.argv[2]

def table(schema):
    xml = subprocess.run(
        ['xcrun', 'xctrace', 'export', '--input', trace, '--xpath',
         f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
        capture_output=True, text=True).stdout
    if not xml.strip():
        return []
    ids, rows = {}, []
    for row in ET.fromstring(xml).iter('row'):
        cells = {}
        for cell in row:
            if 'ref' in cell.attrib:
                cell = ids[cell.attrib['ref']]
            elif 'id' in cell.attrib:
                ids[cell.attrib['id']] = cell
            cells.setdefault(cell.tag, cell.text)
            if cell.tag == 'process':
                cells['process'] = cell.attrib.get('fmt', '')
        rows.append(cells)
    return rows

hitches = [r for r in table('hitches') if 'xctest' in r.get('process', '')]
if not hitches:
    print('hitches: 0 回（または xctrace が記録できなかった）')
    sys.exit(0)
starts = [int(r['start-time']) / 1e9 for r in hitches]
durations = [int(r['duration']) / 1e6 for r in hitches]
span = max(starts) - min(starts) if len(starts) > 1 else 1
total = sum(durations)
print(f'hitches {len(hitches)} 回, 計 {total:.0f}ms, 記録の区間 {span:.1f}s で {total / span:.1f} ms/s')
PY
done

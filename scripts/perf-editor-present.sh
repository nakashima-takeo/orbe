#!/usr/bin/env bash
# 画面に出す計測（朝の場で回し、その結果を正とする。関門にはしない）。窓を画面に出すので、画面のロックを外し、スリープ
# させずに回す（アプリは activate しない）。release のテスト用ビルドで EditorPresentPerfTests を xctrace（Animation
# Hitches ＋ os_signpost）の下で起こし、1MB に合成の指の出来事を約 5.7ms ごとに流して、記録係の要約（出来事→present・
# 落ちたコマ）と hitches を並べる。hitches は、テストが os_signpost の interval（scrolling）で記録した出来事を流している
# 区間の中のものだけを足し、区間の長さの合計で割る。目標は docs/testing/test-architecture.md。
#
#   scripts/perf-editor-present.sh [out_dir]
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-.preview/perf-present}"
mkdir -p "$out"

swift build --build-tests -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG 2>&1 \
  | grep -E "error:|Build complete" | tail -3
xctest=$(xcrun --find xctest)
xctrace=$(xcrun --find xctrace)

trace="$out/scrolling.trace"
rm -rf "$trace"
began=$(date '+%Y-%m-%d %H:%M:%S')
ORBE_EDITOR_PRESENT=1 "$xctrace" record --template 'Animation Hitches' \
  --instrument os_signpost --time-limit 40s --output "$trace" --target-stdout - --launch -- \
  "$xctest" -XCTest "OrbeTests.EditorPresentPerfTests/testScrolling" \
  .build/release/OrbeTests.xctest > "$out/scrolling.stdout" 2>&1 || true
grep -E "error:|failed" "$out/scrolling.stdout" || true
log show --start "$began" --style compact \
  --predicate 'category == "editor-frames" AND process == "xctest"' \
  | grep -E "gesture" || echo "（記録係の要約が見つからない）"
python3 - "$trace" <<'PY'
# xctrace の hitches 表から、スクロールを動かしている区間（os_signpost の interval scrolling）の中の hitches を足し、
# 区間の長さの合計で割る。時刻はどちらも trace の起点からの ns。
import subprocess, sys, xml.etree.ElementTree as ET

trace = sys.argv[1]

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

spans = [
    (int(r['start-time']), int(r['start-time']) + int(r['duration']))
    for r in table('OSSignpostIntervals')
    if r.get('signpost-name') == 'scrolling' and r.get('subsystem') == 'dev.orbe.perf'
]
if not spans:
    print('スクロールの区間が trace に無い（テストが走らなかったか、os_signpost が記録されなかった）')
    sys.exit(0)
length = sum(end - start for start, end in spans) / 1e9
total, count = 0.0, 0
for r in table('hitches'):
    if 'xctest' not in r.get('process', ''):
        continue
    start = int(r['start-time'])
    end = start + int(r['duration'])
    for lo, hi in spans:
        if lo <= start < hi:
            total += (min(end, hi) - start) / 1e6
            count += 1
            break
print(f'hitches {count} 回, 計 {total:.0f}ms, スクロールの区間 {length:.1f}s で {total / length:.1f} ms/s')
PY

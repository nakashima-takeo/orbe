#!/usr/bin/env bash
# 画面に出す計測（朝の場で回し、その結果を正とする。関門にはしない）。窓を画面に出すので、画面のロックを外し、スリープ
# させずに回す（アプリは activate しない）。release のテスト用ビルドで EditorPresentPerfTests を xctrace（Animation
# Hitches ＋ os_signpost）の下で起こし、次を並べる:
#   - 新しい面（Metal）: 1MB に合成の指の出来事を約 5.7ms ごとに流す。記録係の要約（出来事→present・落ちたコマ）と hitches
#   - 今の面（STTextView）: 非公開の _automateLiveScroll で本物のスクロールの経路を回す。hitches
# hitches は、テストが os_signpost の interval（scrolling）で記録したスクロールを動かしている区間の中のものだけを足し、
# 区間の長さの合計で割る（両方の面とも同じ定義）。目標は docs/testing/test-architecture.md。
#
# 環境変数は .app を Finder から起こしたときと同じに絞る（perf-editor.sh と同じ理由。xctrace は起こすプロセスへ親の環境を
# そのまま渡すので、xctrace ごと絞った環境の下で起こす）。最初に /usr/bin/env を同じ形で起こし、絞れているかを確かめる。
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

isolated() {
  env -i \
    HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" SHELL="${SHELL:-/bin/zsh}" \
    TMPDIR="${TMPDIR:-/tmp/}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    __CF_USER_TEXT_ENCODING="${__CF_USER_TEXT_ENCODING:-0x1F5:0x1:0xE}" \
    SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" OSLogRateLimit=64 COMMAND_MODE=unix2003 \
    __CFBundleIdentifier=dev.orbe.app.dev XPC_SERVICE_NAME=0 XPC_FLAGS=0x0 \
    "$@"
}

# 計測するプロセスへ shell の環境が漏れていないか（漏れていれば今の面の基準値だけが実アプリより遅く出る）。
probe="$out/env-probe.trace"
rm -rf "$probe"
ORBE_ENV_PROBE=leaked isolated "$xctrace" record --template 'Animation Hitches' --time-limit 5s \
  --output "$probe" --target-stdout - --launch -- /usr/bin/env > "$out/env-probe.stdout" 2>&1 || true
if grep -q ORBE_ENV_PROBE "$out/env-probe.stdout"; then
  echo "環境変数: shell の環境が計測するプロセスへ漏れている（数字を信用しない）"
else
  echo "環境変数: 絞れている（$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$out/env-probe.stdout") 個）"
fi

for surface in Metal Current; do
  trace="$out/$surface.trace"
  rm -rf "$trace"
  began=$(date '+%Y-%m-%d %H:%M:%S')
  isolated ORBE_EDITOR_PRESENT=1 "$xctrace" record --template 'Animation Hitches' \
    --instrument os_signpost --time-limit 40s --output "$trace" --target-stdout - --launch -- \
    "$xctest" -XCTest "OrbeTests.EditorPresentPerfTests/test${surface}Surface" \
    .build/release/OrbeTests.xctest > "$out/$surface.stdout" 2>&1 || true
  echo "== $surface"
  grep -E "error:|failed" "$out/$surface.stdout" || true
  if [[ $surface == Metal ]]; then
    log show --start "$began" --style compact \
      --predicate 'category == "editor-frames" AND process == "xctest"' \
      | grep -E "gesture" || echo "（記録係の要約が見つからない）"
  fi
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
done

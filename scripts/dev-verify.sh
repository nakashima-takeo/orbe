#!/usr/bin/env bash
# Orbe の開発ループ自動化。.app を再ビルド→再起動→制御ソケットで駆動→出力を assert する。
# 再起動の orchestration は制御 API の外側（ソケットはアプリと心中するため自己再起動は循環）。
# 制御 API は「起動後に send_text で流し get_pane_text で確かめる」検証だけを担う。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCK="$HOME/Library/Application Support/dev.orbe.app.dev/control.sock"  # build-app.sh 既定の dev チャネル固定
MCP="$ROOT/.build/release/orbe-mcp"
APP="$ROOT/build/Orbe.app"

call() {  # method argsjson -> result.content[0].text
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
    | "$MCP" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["result"]["content"][0]["text"])'
}

# call() は正常系（result 決め打ち）。error を受けられるよう、control が error を返した
# tools/call は MCP が isError:true の content に message 文字列を載せる。生テキストを返す。
call_text() {  # method argsjson -> result.content[0].text（error でも本文をそのまま返す）
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
    | "$MCP" 2>/dev/null \
    | python3 -c 'import sys,json
r=json.loads(sys.stdin.read())["result"]
print(("ERR:" if r.get("isError") else "")+r["content"][0]["text"])'
}

echo "==> 再ビルド"
"$ROOT/scripts/build-app.sh" >/dev/null
swift build -c release --package-path "$ROOT" --product orbe-mcp >/dev/null

echo "==> 既存インスタンスを終了"
# quit も pkill も dev チャネルの実体だけを狙う（アプリ名解決・部分一致だと本番 Orbe や
# /Applications 側のインスタンスまで巻き添えにする）。
osascript -e 'tell application id "dev.orbe.app.dev" to quit' 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/Orbe" 2>/dev/null || true
rm -f "$SOCK"
sleep 0.5

echo "==> 起動・ソケット待ち"
open "$APP"
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.2; done
[ -S "$SOCK" ] || { echo "FAIL: socket up しない"; exit 1; }

echo "==> 駆動・assert"
PID=$(call list_panes '{}' | python3 -c 'import sys,json
d=json.load(sys.stdin)
live=[p for p in d["panes"] if p["focused"]] or d["panes"]
print(live[0]["paneId"])')
TOKEN="DEV_VERIFY_$$"
# send_text はペースト相当で自己実行しない。enter を別送して実際に実行させる。
call send_text "{\"paneId\":$PID,\"text\":\"echo $TOKEN\"}" >/dev/null
call send_key "{\"paneId\":$PID,\"key\":\"enter\"}" >/dev/null
# 再起動直後はシェルの出力が遅れる。固定 sleep でなく出現するまでポーリング（最大 ~7.5s）。
# 入力エコー＋実行された出力で token は 2 回以上出る（未実行なら 1 回）。出現数で数える
# （grep -c は行数で soft-wrap に弱い。call は抽出済みテキストを返す）。
ok=0
for _ in $(seq 1 25); do
  COUNT=$(call get_pane_text "{\"paneId\":$PID}" \
    | python3 -c "import sys; print(sys.stdin.read().count('$TOKEN'))")
  if [ "${COUNT:-0}" -ge 2 ]; then ok=1; break; fi
  sleep 0.3
done
if [ "$ok" = 1 ]; then
  echo "PASS: 制御チャネルでコマンドが実行・観測できた (pane $PID, token×$COUNT)"
else
  echo "FAIL: コマンドが実行されていない (token×${COUNT:-0})"; exit 1
fi

echo "==> activate_workspace / dormantAgentCount assert"

# ② list_workspaces の各 ws に dormantAgentCount フィールドが出る。
if call list_workspaces '{}' | python3 -c 'import sys,json
ws=json.load(sys.stdin)["workspaces"]
assert ws, "no workspaces"
assert all("dormantAgentCount" in w for w in ws), "dormantAgentCount 欠落"'; then
  echo "PASS: list_workspaces に dormantAgentCount が露出している"
else
  echo "FAIL: list_workspaces に dormantAgentCount が無い"; exit 1
fi

# ① 背景（active==false）workspace を activate → 返る paneIds の先頭で get_pane_text が非空になる。
# 背景 WS が無ければ（単一 WS 環境）このケースはスキップ。
BGWS=$(call list_workspaces '{}' | python3 -c 'import sys,json
ws=json.load(sys.stdin)["workspaces"]
bg=[w for w in ws if not w["active"]]
print(bg[0]["id"] if bg else "")')
if [ -n "$BGWS" ]; then
  APANE=$(call activate_workspace "{\"workspaceId\":$BGWS}" | python3 -c 'import sys,json
pids=json.load(sys.stdin)["paneIds"]
print(pids[0] if pids else "")')
  [ -n "$APANE" ] || { echo "FAIL: activate_workspace が paneIds を返さない"; exit 1; }
  ok=0
  for _ in $(seq 1 25); do
    LEN=$(call get_pane_text "{\"paneId\":$APANE}" | python3 -c 'import sys; print(len(sys.stdin.read().strip()))')
    if [ "${LEN:-0}" -gt 0 ]; then ok=1; break; fi
    sleep 0.3
  done
  if [ "$ok" = 1 ]; then
    echo "PASS: 背景 workspace を activate してペイン $APANE が読めた"
  else
    echo "FAIL: activate 後もペイン $APANE が空"; exit 1
  fi
else
  echo "SKIP: 背景 workspace が無いため activate→非空 検証を省略"
fi

# ③ 不正 workspaceId は error（MCP ブリッジは code を message へ畳むため message で判定）。
ERR=$(call_text activate_workspace '{"workspaceId":999999}')
case "$ERR" in
  ERR:*workspace*not*found*) echo "PASS: 不正 workspaceId が error を返した ($ERR)";;
  *) echo "FAIL: 不正 workspaceId が error にならない ($ERR)"; exit 1;;
esac

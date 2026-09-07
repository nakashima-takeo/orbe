#!/usr/bin/env bash
# 隔離した使い捨て Orbe を起こす・叩く・片付ける（.claude/skills/sandbox-run の実体）。
#
#   sandbox-run.sh start [<app>]                      隔離起動 → 煙探知 → state_dir / sock / pid / build_id を出す
#   sandbox-run.sh rpc <state_dir> <method> [<params-json>] [<timeout-sec>]
#                                                     隔離インスタンスの control.sock へ JSON-RPC を 1 本投げ result を出す
#   sandbox-run.sh stop <state_dir>                   インスタンスを止め、state dir を消す
#
# 本物の Orbe（常用の workspaces・control.sock）には一切触れない:
# - state の隔離: ORBE_STATE_DIR を mktemp -d に向ける（workspaces・control.sock がその直下へ隔離される）。
#   control.sock は AF_UNIX の sun_path 104 バイト上限を超えると警告なく無効化されるので、mktemp -d より深い場所は選ばない。
# - 環境の隔離: 親 Orbe がタブへ注入した ORBE_SOCK / ORBE_TAB（親インスタンス）、ORBE_REPORT_BIN / ORBE_BUNDLE_ID /
#   GHOSTTY_* / TERMINFO（親バンドル）、ZDOTDIR（親の補完 shim）を外す。ORBE_STATE_DIR は state しか隔離せず
#   プロセス環境は素通りするため、残すと隔離インスタンスが本物へ接続したり旧バンドルの資産を読んだりする。
# - open は使わない: 起動中のインスタンスを前面化するだけで新ビルドに入れ替わらない。バイナリを直接起こす。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TTL_SEC=3600  # 片付けが走らなかったときの自壊時限（孤児化した GUI が CPU を食い続けないため）

usage() {
  sed -n '2,8p' "$0" >&2
  exit 2
}

# 隔離インスタンスの control.sock へ JSON-RPC を 1 本投げ、result を JSON で stdout に出す。
# 応答の改行まで受信してから閉じる（ControlServer はクライアント側 EOF で接続を閉じるため、送信側が先に閉じると応答が取れない）。
rpc_call() {
  local sock="$1" method="$2" params="${3:-{\}}" timeout="${4:-5}"
  python3 - "$sock" "$method" "$params" "$timeout" <<'PY'
import json
import socket
import sys

sock_path, method, params, timeout = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), float(sys.argv[4])
request = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(timeout)
    sock.connect(sock_path)
    sock.sendall((json.dumps(request) + "\n").encode())
    with sock.makefile("rb") as stream:
        line = stream.readline()
if not line.endswith(b"\n"):
    sys.exit("control.sock: 応答の改行前に切断された")
response = json.loads(line)
if response.get("id") != request["id"]:
    sys.exit("control.sock: 応答の id が一致しない")
if "error" in response:
    sys.exit(json.dumps(response["error"], ensure_ascii=False))
print(json.dumps(response.get("result"), ensure_ascii=False))
PY
}

kill_wait() {  # pid を止め、消えるまで最大 5 秒待つ
  local pid="$1"
  kill "$pid" 2>/dev/null || return 0
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.25; done
  kill -9 "$pid" 2>/dev/null || true
}

do_stop() {
  local state_dir="$1"
  [ -d "$state_dir" ] || { echo "==> 既に片付いている: $state_dir"; return 0; }
  if [ -f "$state_dir/watchdog.pid" ]; then
    local wd; wd="$(cat "$state_dir/watchdog.pid")"
    pkill -P "$wd" 2>/dev/null || true  # 時限の sleep
    kill "$wd" 2>/dev/null || true
  fi
  [ -f "$state_dir/sandbox.pid" ] && kill_wait "$(cat "$state_dir/sandbox.pid")"
  rm -rf "$state_dir"
  echo "==> 片付け完了: $state_dir"
}

do_start() {
  local app="${1:-$ROOT/build/Orbe.app}"
  local bin="$app/Contents/MacOS/Orbe"
  [ -x "$bin" ] || { echo "エラー: $bin が無い。./scripts/build-app.sh でビルドするか、起こす .app を渡せ" >&2; exit 1; }
  local build_id
  build_id="$(/usr/libexec/PlistBuddy -c 'Print :OrbeBuildID' "$app/Contents/Info.plist" 2>/dev/null || echo unknown)"

  local state_dir; state_dir="$(mktemp -d)"
  local sock="$state_dir/control.sock" log="$state_dir/orbe.log"

  local scrub=(env
    -u ORBE_STATE_DIR -u ORBE_SOCK -u ORBE_TAB
    -u ORBE_REPORT_BIN -u ORBE_BUNDLE_ID -u ORBE_USER_ZDOTDIR
    -u GHOSTTY_RESOURCES_DIR -u GHOSTTY_BIN_DIR -u GHOSTTY_SURFACE_ID
    -u GHOSTTY_SHELL_FEATURES -u GHOSTTY_ZSH_ZDOTDIR -u TERMINFO
  )
  # ORBE_USER_ZDOTDIR は親 GUI（CompletionShim.activate()）が据えたユーザー本来の ZDOTDIR。あれば復元し、
  # 無くても親 Orbe 内（ORBE_BUNDLE_ID あり）なら親 shim を指す ZDOTDIR を消す。Orbe 外からの起動ではユーザーの値を保つ。
  if [ -n "${ORBE_USER_ZDOTDIR:-}" ]; then
    scrub+=(ZDOTDIR="$ORBE_USER_ZDOTDIR")
  elif [ -n "${ORBE_BUNDLE_ID:-}" ]; then
    scrub+=(-u ZDOTDIR)
  fi

  "${scrub[@]}" ORBE_STATE_DIR="$state_dir" "$bin" >"$log" 2>&1 &
  local pid=$!
  echo "$pid" >"$state_dir/sandbox.pid"
  ( sleep "$TTL_SEC"; kill "$pid" 2>/dev/null; sleep 1; rm -rf "$state_dir" ) >/dev/null 2>&1 &
  echo $! >"$state_dir/watchdog.pid"

  fail() {
    echo "FAIL: $1" >&2
    [ -f "$log" ] && { echo "--- $log (tail)" >&2; tail -n 20 "$log" >&2; }
    do_stop "$state_dir" >&2
    exit 1
  }

  # GUI の起動から ControlServer が bind するまでには実時間がある。待たずに叩くと健全なバンドルを不合格にする。
  for _ in $(seq 1 40); do [ -S "$sock" ] && break; sleep 0.25; done
  [ -S "$sock" ] || fail "control.sock が 10 秒で現れない（起動経路が ControlServer を張っていない）"

  # 煙探知: .app の起動経路と AppDelegate の配線は swift test の守備範囲外なので、ここで機械的に確かめる。
  # 目印をコマンド行の中で 2 つのリテラルに割り、シェルが引用符除去を評価した出力にしか現れない連結形を待つ
  # （入力行の描き返しでは合格にならないので、利用者の rc とテーマが走る実 .app でも判定が揺れない）。
  local tab=""
  for _ in $(seq 1 40); do
    tab="$(rpc_call "$sock" list_tabs '{}' 2>/dev/null | python3 -c 'import json,sys; t=json.load(sys.stdin)["tabs"]; print(t[0]["tabId"] if t else "")' 2>/dev/null || true)"
    [ -n "$tab" ] && break
    sleep 0.25
  done
  [ -n "$tab" ] || fail "タブが 10 秒で現れない"
  sleep 1  # シェルが立ち上がる猶予
  local marker="L4DONE_${RANDOM}${RANDOM}"
  rpc_call "$sock" send_text "{\"tabId\":$tab,\"text\":\"echo L4D\\\"\\\"ONE_${marker#L4DONE_}\"}" >/dev/null || fail "send_text に失敗"
  rpc_call "$sock" send_key "{\"tabId\":$tab,\"key\":\"enter\"}" >/dev/null || fail "send_key に失敗"
  local seen=""
  for _ in $(seq 1 60); do
    if rpc_call "$sock" get_tab_text "{\"tabId\":$tab}" 2>/dev/null | grep -q "$marker"; then seen=1; break; fi
    sleep 0.25
  done
  [ -n "$seen" ] || fail "煙探知の目印 $marker が 15 秒で出ない（制御 API から駆動できていない）"

  cat <<EOF
state_dir=$state_dir
sock=$sock
pid=$pid
build_id=$build_id
log=$log
smoke=ok
EOF
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  start) do_start "$@" ;;
  rpc)
    [ $# -ge 2 ] || usage
    state_dir="$1"; shift
    sock="$state_dir/control.sock"
    [ -S "$sock" ] || { echo "エラー: $sock が無い" >&2; exit 1; }
    rpc_call "$sock" "$@"
    ;;
  stop)
    [ $# -eq 1 ] || usage
    do_stop "$1"
    ;;
  *) usage ;;
esac

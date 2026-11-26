#!/usr/bin/env bash
# CI の build-test のテストのステップの実体。`swift test --skip-build` を見張りながら走らせる。
#
#   scripts/ci-test.sh <出力ディレクトリ> [swift test の引数...]
#
# - 出力: 疑似端末の下で走らせ（`script`）、テストの出力を行ごとに標準出力と <出力ディレクトリ>/swift-test.log へ出す。
#   パイプの先では `swift test` が XCTest の出力を塊でため、テストが固まると最後の塊がログに出ない。テストの中の print
#   （xctest の標準出力）は、疑似端末の下でも xctest の中でたまるので、`NSUnbufferedIO` で行ごとに出させる。
# - 見張り: ログが STALL_SECONDS 秒伸びないか、開始から LIMIT_SECONDS 秒を超えたら、固まったとみなす。配下の xctest（無ければ
#   配下のすべて）に `sample` をかけ、結果を標準出力と <出力ディレクトリ>/sample-<pid>.txt へ出し、配下を終わらせ、1 で終わる。
#   見張るのも終わらせるのも、このスクリプトが起動したプロセスの配下だけ。
# - 終了コード: 固まらなければ `swift test` のもの。
set -uo pipefail

# 1 本のテストが出力なしで走る最長は、成功した CI で 24 秒台（main への push で走る長時間ファズ）。その 10 倍を超える長さ。
STALL_SECONDS=300
# ステップ全体の上限。ジョブの上限（60 分）からビルドの時間（成功した CI で 6 分前後）を引いた残りに収める。
LIMIT_SECONDS=2700
POLL_SECONDS=5

out=$1
shift
mkdir -p "$out"
log="$out/swift-test.log"
: >"$log"

NSUnbufferedIO=YES script -q -F "$log" swift test --skip-build "$@" </dev/null &
pid=$!

descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "$child"
    descendants "$child"
  done
}

trap 'kill $(descendants "$pid") "$pid" 2>/dev/null; exit 143' TERM INT

started=$SECONDS
grown=$SECONDS
size=0
while kill -0 "$pid" 2>/dev/null; do
  sleep "$POLL_SECONDS"
  current=$(stat -f %z "$log")
  if [ "$current" != "$size" ]; then
    size=$current
    grown=$SECONDS
  fi
  if ((SECONDS - grown < STALL_SECONDS && SECONDS - started < LIMIT_SECONDS)); then
    continue
  fi

  echo "::error::テストの出力が $((SECONDS - grown)) 秒伸びない（開始から $((SECONDS - started)) 秒）。配下のプロセスに sample をかけて終わらせる。"
  all=$(descendants "$pid")
  targets=$(for p in $all; do
    [ "$(basename "$(ps -o comm= -p "$p")")" = xctest ] && echo "$p"
  done)
  targets=${targets:-$all}
  for p in $targets; do
    echo "::group::sample $p $(ps -o command= -p "$p")"
    # 権限エラーになったときは、CI の実行環境が持つパスワード無しの sudo で `sample` を取り直す。
    sample "$p" 5 -file "$out/sample-$p.txt" >/dev/null ||
      sudo -n sample "$p" 5 -file "$out/sample-$p.txt" >/dev/null
    cat "$out/sample-$p.txt"
    echo "::endgroup::"
  done
  kill $targets 2>/dev/null
  for _ in $(seq 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill -KILL $(descendants "$pid") "$pid" 2>/dev/null
  wait "$pid"
  exit 1
done
wait "$pid"

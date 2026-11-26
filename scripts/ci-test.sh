#!/usr/bin/env bash
# CI の build-test のテストのステップの実体。`swift test --skip-build` を見張りながら走らせる。
#
#   scripts/ci-test.sh <出力ディレクトリ> [swift test の引数...]
#
# - 出力: テストの出力を、行ごとに標準出力と <出力ディレクトリ>/swift-test.log へ出す。パイプの先では `swift test` が出力を
#   塊でため、テストが固まると最後の塊がログに出ないので、`NSUnbufferedIO` で行ごとに出させる。`$!` を `swift test` の pid に
#   保つため、tee へはプロセス置換で渡す。疑似端末の下では走らせない（テストが起こす `zsh -i` が端末を取りに行って止まる）。
# - 見張り: ログが STALL_SECONDS 秒伸びないか、開始から LIMIT_SECONDS 秒を超えたら、固まったとみなす。最後に始まったテストの
#   名前を含む注釈を出し、配下の xctest（無ければ配下のすべて）に `sample` をかけ、結果を標準出力と
#   <出力ディレクトリ>/sample-<pid>.txt へ出し、配下を終わらせ、終了コード 1 で終わる。GitHub Actions の下では、ステップの
#   出力 `stalled` を true にする。見張るのも終わらせるのも、このスクリプトが起動したプロセスの配下だけ。
# - 終了コード: 固まらなければ `swift test` のもの。
#
# `-e` は付けない。`sample` や `kill` が失敗しても、配下を終わらせるところまで必ず進めるため。
set -uo pipefail

# 1 本のテストが出力なしで走る最長は、成功した CI で 24 秒台（main への push で走る長時間ファズ）。その 10 倍を超える長さ。
STALL_SECONDS=300
# このステップの所要は、成功した CI の直近 46 回で 642〜1210 秒（main への push の長時間ファズを含む）。上限は、その最長の
# 約 2 倍で、ビルドが長引いた実行（ビルド 15 分 40 秒）でもジョブの上限（60 分）より先に来る長さ。
LIMIT_SECONDS=2400
POLL_SECONDS=5

out=$1
shift
mkdir -p "$out"
log="$out/swift-test.log"
: >"$log"

NSUnbufferedIO=YES swift test --skip-build "$@" </dev/null > >(tee "$log") 2>&1 &
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
  if ((SECONDS - grown >= STALL_SECONDS)); then
    reason="テストの出力が $((SECONDS - grown)) 秒伸びない（開始から $((SECONDS - started)) 秒）"
  elif ((SECONDS - started >= LIMIT_SECONDS)); then
    reason="テストのステップが上限の $LIMIT_SECONDS 秒を超えた"
  else
    continue
  fi

  last=$(grep -o "Test Case '[^']*' started" "$log" | tail -1 | sed -E "s/Test Case '(.*)' started/\1/")
  echo "::error::${reason}。最後に始まったテスト: ${last:-無し}。配下のプロセスに sample をかけて終わらせる。"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "stalled=true" >>"$GITHUB_OUTPUT"
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
  # SIGKILL は、sample の前に取った配下の一覧（`all`）にも送る。xctest が終わると、その子（別のプロセスグループで起こした
  # ものなど）は配下から外れ、数え直しても見つからない。
  kill -KILL $all $(descendants "$pid") "$pid" 2>/dev/null
  wait "$pid"
  exit 1
done
wait "$pid"

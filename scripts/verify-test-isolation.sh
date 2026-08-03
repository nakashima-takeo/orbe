#!/usr/bin/env bash
# `swift test` がユーザーの実環境（ghostty の user 設定・Orbe の state dir）へ書き込まないことを実証する。
# CI には載せない。テスト隔離ハーネス（Tests/OrbeTests/TestIsolation.swift）を触る人が
# 同じ検証を再発明しないために置く。
#
# 検出できるのは書き込み・新規作成だけ（atime は当てにならないので読み取りは測れない）。
# user 設定の読み取りは `Config.userFileURLOverride` が
# `ghostty_config_load_default_files` を構造的に呼ばせないことで担保する。
#
# 前提: Orbe 本体を終了しておく（起動中のインスタンスが state dir を書くと差分が出る）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH=(
  "$HOME/.config/ghostty"
  "$HOME/Library/Application Support/com.mitchellh.ghostty"
  "$HOME/Library/Application Support/dev.orbe.app.dev"
  "$HOME/Library/Application Support/dev.orbe.app"
  # 隔離なしの `swift test` が state dir を作る先。application support は bundle id で分岐し、
  # テスト実行体の bundle id は xctest ツールのものになる。
  "$HOME/Library/Application Support/com.apple.dt.xctest.tool"
)

snapshot() {  # -> stdout（パス・サイズ・mtime。不在ディレクトリは 1 行の印で表す）
  for d in "${WATCH[@]}"; do
    if [ -e "$d" ]; then
      find "$d" -exec stat -f '%N %z %m' {} \; | sort
    else
      echo "ABSENT $d"
    fi
  done
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"

echo "==> 実ホームの監視対象をスナップショット"
snapshot >"$WORK/before"

# HOME を差し替えたまま build すると SwiftPM が依存を偽ホームへ解決し直す。先に実 HOME で建てる。
echo "==> 実 HOME でビルド"
swift build --package-path "$ROOT" --build-tests >/dev/null

echo "==> 偽ホームで swift test（1 回だけ）"
set +e
env HOME="$FAKE_HOME" XDG_CONFIG_HOME="$FAKE_HOME/.config" \
  swift test --package-path "$ROOT" --skip-build >"$WORK/test.log" 2>&1
TEST_STATUS=$?
set -e
[ "$TEST_STATUS" -eq 0 ] || echo "NOTE: swift test は失敗した (exit $TEST_STATUS)。汚染判定は続行する。詳細: $WORK/test.log"

echo "==> 偽ホーム配下の新規作成を確認"
FAKE_DIRT=0
for sub in ".config/ghostty" "Library/Application Support"; do
  if [ -e "$FAKE_HOME/$sub" ]; then
    echo "DIRTY: 偽ホームに $sub が作られた"
    find "$FAKE_HOME/$sub" | sed 's/^/  /'
    FAKE_DIRT=1
  fi
done

echo "==> 実ホームのスナップショットと突き合わせ"
snapshot >"$WORK/after"
if diff -u "$WORK/before" "$WORK/after" >"$WORK/diff"; then
  REAL_DIRT=0
else
  echo "DIRTY: 実ホームの監視対象に差分がある"
  sed 's/^/  /' "$WORK/diff"
  REAL_DIRT=1
fi

if [ "$FAKE_DIRT" = 0 ] && [ "$REAL_DIRT" = 0 ]; then
  echo "PASS: swift test はユーザーのホームと ghostty 設定を書き換えなかった"
else
  echo "FAIL: swift test が実環境へ書き込んでいる"
  exit 1
fi

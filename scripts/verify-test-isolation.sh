#!/usr/bin/env bash
# `swift test` がユーザーの実環境（ghostty の user 設定・Orbe の state dir）へ書き込まないことを実証する。
# CI には載せない。テスト隔離ハーネス（Tests/OrbeTests/TestIsolation.swift）を触る人が
# 同じ検証を再発明しないために置く。
#
# 検出できるのは書き込み・新規作成だけ（atime は当てにならないので読み取りは測れない）。
# user 設定の読み取りは `Config.userFileURLOverride` が
# `ghostty_config_load_default_files` を構造的に呼ばせないことで担保する。
#
# 測っていないもの: `UserDefaults`。standard domain は cfprefsd がユーザーレコードで解決するので
# HOME 差し替えでは曲がらず、テスト実行体の bundle id（xctest ツール）の plist が実ホームへ残る。
# ハーネスも隔離していない（roadmap の前倒しリファクタ表を参照）。
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
  # 補完の legacy 掃除（`CompletionLegacyCleanup`）が書き換える先。ここだけは override を通らず
  # 実体を解く経路なので、ハーネスの隔離ではなくデータ条件で止まっている。解決順は
  # ORBE_USER_ZDOTDIR → ZDOTDIR → ホームの 3 段で、どれが立っているかは実行環境次第なので全部張る
  # （Orbe のペインから `swift test` を走らせると、shim が立てた ZDOTDIR / ORBE_USER_ZDOTDIR を継ぐ）。
  "${ORBE_USER_ZDOTDIR:-$HOME}/.zshrc"
  "${ZDOTDIR:-$HOME}/.zshrc"
  "$HOME/.zshrc"
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
# swift test が落ちたときに読むログの退避先（$WORK は EXIT で消える）。
KEPT_LOG="$ROOT/.build/verify-test-isolation.log"

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
if [ "$TEST_STATUS" -ne 0 ]; then
  cp "$WORK/test.log" "$KEPT_LOG"
  echo "NOTE: swift test は失敗した (exit $TEST_STATUS)。汚染判定は続行する。詳細: $KEPT_LOG"
fi

# HOME を honor する書き手（shell shim・libghostty 等）だけがここに現れる。Foundation 経由は
# 現れない——`applicationSupportDirectory` は cfprefsd 同様ユーザーレコードで解決し HOME を見ない。
# Foundation 経由の汚染を捕まえるのは下の実ホーム差分の方で、こちらはその補助。
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

if [ "$FAKE_DIRT" != 0 ] || [ "$REAL_DIRT" != 0 ]; then
  echo "FAIL: swift test が実環境へ書き込んでいる"
  exit 1
fi

# テストが 1 本も走らずに落ちた場合（installOnce の precondition / fatalError 発火が典型）も
# 「どこも汚れていない」になる。走っていない実行を PASS と呼ぶと、隔離が完全に壊れた状態を
# 「検証済み」と読ませてしまうので、実行本数を判定に入れる。
EXECUTED="$(sed -n 's/.*Executed \([0-9][0-9]*\) tests.*/\1/p' "$WORK/test.log" | sort -rn | head -1)"
if [ -z "$EXECUTED" ] || [ "$EXECUTED" -eq 0 ]; then
  cp "$WORK/test.log" "$KEPT_LOG"
  echo "FAIL: テストが 1 本も走っていない（隔離の点火が落ちた可能性）。詳細: $KEPT_LOG"
  exit 1
fi

echo "PASS: swift test（$EXECUTED 本）は ghostty の user 設定と Orbe の state dir を書き換えなかった"
[ "$TEST_STATUS" -eq 0 ] || echo "（ただし swift test 自体は exit ${TEST_STATUS}。汚染判定とは独立）"

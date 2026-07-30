#!/bin/sh
# Orbe エージェント状態追跡プラグインを検出された各 CLI へ冪等に導入する。
# Orbe が実体化先のパスとプラグイン名を引数にバックグラウンドで呼ぶ。
#
# 使い方: install.sh <plugin_dir> <plugin_name>
# プラグイン名はチャネルごとに違う（dev / release が別枠で共存する）ので焼き付けず引数で受ける。
# 各 CLI ごとに status を 1 行出力: installed / unchanged / skip-no-cli / error
# 個々の CLI のハングを tmo で打ち切る。
DIR="${1:?plugin_dir required}"
NAME="${2:?plugin_name required}"

# macOS に timeout が無いため perl の alarm で代替（exit 124 で打ち切り）。
tmo() { perl -e 'alarm shift; exec @ARGV' "$@" </dev/null >/dev/null 2>&1; }

# 各 CLI の開始時に "start <cli>" を出し、UI が「導入中」を出せるようにする（echo は逐次 write）。
echo "start claude"
if command -v claude >/dev/null 2>&1; then
  tmo 30 claude plugin marketplace add "$DIR"
  # list は "<name>@<marketplace>" の行を持つ。別チャネルの枠（名前の先頭が同じ）を自分のものと
  # 誤認して plugin install を永久に飛ばさないよう、完全一致で判定する。
  if claude plugin list 2>/dev/null | grep -qF "${NAME}@${NAME}"; then
    echo "unchanged claude"
  elif tmo 60 claude plugin install "${NAME}@${NAME}"; then
    echo "installed claude"
  else
    echo "error claude"
  fi
else
  echo "skip-no-cli claude"
fi

echo "start codex"
if command -v codex >/dev/null 2>&1; then
  # list は "<name>@<mkt>  not installed|installed  <path>"。導入済みのみ unchanged に
  # する（"not installed" 行を拾わないよう name の直後が installed の行で判定）。
  if codex plugin list 2>/dev/null | grep -qE "${NAME}@${NAME}[[:space:]]+installed"; then
    echo "unchanged codex"
  else
    tmo 30 codex plugin marketplace add "$DIR"
    if tmo 60 codex plugin add "${NAME}@${NAME}"; then
      echo "installed codex"
    else
      echo "error codex"
    fi
  fi
else
  echo "skip-no-cli codex"
fi

echo "start agy"
if command -v agy >/dev/null 2>&1; then
  # agy はローカルパス導入＝プラグイン本体の subdir（plugin.json のあるルート）を指す。
  # list は JSON（`"name": "<name>"`）なので引用符込みの完全一致で判定する（claude と同じ理由）。
  if agy plugin list 2>/dev/null | grep -qF "\"${NAME}\""; then
    echo "unchanged agy"
  elif tmo 60 agy plugin install "$DIR/plugins/$NAME"; then
    echo "installed agy"
  else
    echo "error agy"
  fi
else
  echo "skip-no-cli agy"
fi

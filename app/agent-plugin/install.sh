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

# macOS に timeout が無いため perl の alarm で代替（alarm は exec を越えて残る）。
# stderr は常に捨てる: このスクリプトの stdout は status 行の通り道で、混ざると Orbe が誤読する。
tmo() { perl -e 'alarm shift; exec @ARGV' "$@" </dev/null 2>/dev/null; }

# list の出力はパイプでなくこのファイルで受ける（毎回 truncate される）。CLI が孫プロセスを残した
# まま打ち切られても、孫が握るのはこの fd なので grep は EOF を待たない（パイプだと孫が閉じるまで
# 待ち続け、打ち切りが効かない）。打ち切り時は空＝未登録扱いで install を試す＝誤って unchanged を
# 名乗って導入を永久に飛ばすより安全な倒れ方。
LIST="$(mktemp -t orbe-plugin-list)" || exit 1
trap 'rm -f "$LIST"' EXIT

# 各 CLI の開始時に "start <cli>" を出し、UI が「導入中」を出せるようにする（echo は逐次 write）。
echo "start claude"
if command -v claude >/dev/null 2>&1; then
  tmo 30 claude plugin marketplace add "$DIR" >/dev/null
  # list は "<name>@<marketplace>" の行を持つ。別チャネルの枠（名前の先頭が同じ）を自分のものと
  # 誤認して plugin install を永久に飛ばさないよう、完全一致で判定する。
  tmo 15 claude plugin list >"$LIST"
  if grep -qF "${NAME}@${NAME}" "$LIST"; then
    echo "unchanged claude"
  elif tmo 60 claude plugin install "${NAME}@${NAME}" >/dev/null; then
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
  tmo 15 codex plugin list >"$LIST"
  if grep -qE "${NAME}@${NAME}[[:space:]]+installed" "$LIST"; then
    echo "unchanged codex"
  else
    tmo 30 codex plugin marketplace add "$DIR" >/dev/null
    if tmo 60 codex plugin add "${NAME}@${NAME}" >/dev/null; then
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
  tmo 15 agy plugin list >"$LIST"
  if grep -qF "\"${NAME}\"" "$LIST"; then
    echo "unchanged agy"
  elif tmo 60 agy plugin install "$DIR/plugins/$NAME" >/dev/null; then
    echo "installed agy"
  else
    echo "error agy"
  fi
else
  echo "skip-no-cli agy"
fi

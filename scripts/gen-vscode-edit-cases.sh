#!/usr/bin/env bash
# テキスト面の編集の規則の正解を VS Code で作る。monaco-editor（VS Code のエディターの核を esm にしたもの）と jsdom を一時の
# 場所へ取り、deno で動かして次の 2 つを書き直す。
# - Tests/OrbeEditorEngineTests/VSCodeEditCases.swift（語の規則。scripts/vscode-edit-cases.mjs）
# - Tests/OrbeEditorEngineTests/VSCodeMultiCursorCases.swift（複数カーソルの規則。scripts/vscode-multicursor-cases.mjs。
#   編集器を jsdom の上に作るので、monaco の css の import を外した写しを使う）
set -euo pipefail
cd "$(dirname "$0")/.."

version=0.57.0
jsdom=26.1.0
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/vscode-cases.XXXXXX")" && pwd -P)
trap 'rm -rf "$work"' EXIT
(cd "$work" && npm pack --silent "monaco-editor@$version" >/dev/null && tar xzf monaco-editor-*.tgz)
(cd "$work" && npm install --silent --no-save --no-package-lock "jsdom@$jsdom" >/dev/null)
grep -rlE "^import '[^']*\.css';$" "$work/package/esm" | xargs sed -i '' -E "/^import '[^']*\.css';$/d"

out=Tests/OrbeEditorEngineTests/VSCodeEditCases.swift
MONACO="$work/package" MONACO_VERSION="$version" \
  deno run --allow-read="$work" --allow-env scripts/vscode-edit-cases.mjs > "$out"
swift format -i "$out"

out=Tests/OrbeEditorEngineTests/VSCodeMultiCursorCases.swift
MONACO="$work/package" MONACO_VERSION="$version" JSDOM="$work" \
  deno run --allow-read="$work" --allow-env --allow-sys scripts/vscode-multicursor-cases.mjs > "$out"
swift format -i "$out"

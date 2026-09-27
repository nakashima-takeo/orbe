#!/usr/bin/env bash
# 新しいテキスト面の語の規則の正解を VS Code で作る。monaco-editor（VS Code のエディターの核を esm にしたもの）を一時の
# 場所へ取り、scripts/vscode-edit-cases.mjs を deno で動かして Tests/OrbeEditorEngineTests/VSCodeEditCases.swift を書き直す。
set -euo pipefail
cd "$(dirname "$0")/.."

version=0.57.0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(cd "$work" && npm pack --silent "monaco-editor@$version" >/dev/null && tar xzf monaco-editor-*.tgz)
out=Tests/OrbeEditorEngineTests/VSCodeEditCases.swift
MONACO="$work/package" MONACO_VERSION="$version" \
  deno run --allow-read="$work" --allow-env scripts/vscode-edit-cases.mjs > "$out"
swift format -i "$out"

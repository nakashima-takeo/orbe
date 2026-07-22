#!/usr/bin/env bash
# Orbe 制御チャネルの MCP ブリッジ起動ラッパ。
# MCP クライアントの設定（例: `.mcp.json`）から、このスクリプトのパスを command として呼ぶ想定。
# 自身の位置からリポジトリ root を解決し、ビルド済みブリッジを exec する
# （無ければ release ビルド）。設定側にマシン依存の絶対パスを書かずに済ませるため。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/orbe-mcp"

if [ ! -x "$BIN" ]; then
  swift build -c release --package-path "$ROOT" --product orbe-mcp >&2
fi

exec "$BIN"

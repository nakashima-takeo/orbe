#!/usr/bin/env bash
# Orbe 制御チャネルの MCP ブリッジ起動ラッパ。
# MCP クライアントの設定（例: `.mcp.json`）から、このスクリプトのパスを command として呼ぶ想定。
# 自身の位置からリポジトリ root を解決し、ブリッジをビルドして exec する。
# 設定側にマシン依存の絶対パスを書かずに済ませるため。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/orbe-mcp"

# 接続先は焼いたチャネルで決まる（OrbePaths.fallbackBundleId）。`.build/release` は
# release-app.sh のパッケージ全体ビルドと共有されるため、存在チェックで済ませると本番 identity の
# まま残ったバイナリを掴み、MCP が Orbe Dev ではなく本番の control.sock を叩く。毎回 build を
# 通してチャネル一致を構造で保証する（最新なら no-op、フラグが変わっていれば焼き直す）。
swift build -c release --package-path "$ROOT" --product orbe-mcp >&2

exec "$BIN"

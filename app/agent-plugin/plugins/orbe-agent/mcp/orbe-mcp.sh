#!/bin/sh
# Orbe MCP サーバーのシム。各 CLI がプラグインの MCP 定義から起こし、stdin / stdout を MCP の
# 通り道として使う（このシムは何も出力しない）。
# 自分のチャネルの Orbe のタブ（ORBE_MCP_BIN が .app 同梱の orbe-mcp を指す）なら、それへ exec して
# そのタブの Orbe につなぐ。それ以外（Orbe の外・別チャネルの Orbe のタブ・同梱の無い Orbe）では
# ツール 0 個の空サーバーへ exec する。CLI は有効なプラグインの MCP サーバーを全セッションで起こすので、
# 即終了すると毎回接続失敗として警告されるため。
# チャネルの判定は状態追跡のシム（hooks/orbe-agent-status.sh）と同じ規則: channel は実体化時に Orbe が
# 刻んだ自分の bundle ID、ORBE_BUNDLE_ID はタブを開いた Orbe が名乗る bundle ID。片方が欠けたら通す。

ROOT="$(dirname "$0")/.."
if [ -x "$ORBE_MCP_BIN" ]; then
  OWNER=""
  [ -r "$ROOT/channel" ] && read -r OWNER < "$ROOT/channel"
  if [ -z "$OWNER" ] || [ -z "$ORBE_BUNDLE_ID" ] || [ "$OWNER" = "$ORBE_BUNDLE_ID" ]; then
    exec "$ORBE_MCP_BIN"
  fi
fi
exec /usr/bin/perl "$ROOT/mcp/empty-server.pl"

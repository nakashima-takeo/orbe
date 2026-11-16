#!/bin/sh
# 同梱するエージェントプラグインのパッケージで、codex 専用のディレクトリ（codex/<名前>/）を完成させる。
# plugins/<名前>/ が正として持つシムと空サーバーを、codex 専用のディレクトリへコピーする。codex は hook の承認を、
# 導入されたディレクトリ全体の中身に結び付けるので、claude・agy のファイルと同じディレクトリに置くと、それらが変わる
# たびに承認が外れる。シンボリックリンクにしないのは、codex plugin add が導入のコピーにリンクを含めないため。
#
# 使い方: assemble-codex-plugin.sh <パッケージのディレクトリ> <プラグイン名>
set -eu

PKG="$1"
NAME="$2"
for F in hooks/orbe-agent-status.sh mcp/orbe-mcp.sh mcp/empty-server.pl; do
  mkdir -p "$(dirname "$PKG/codex/$NAME/$F")"
  cp -p "$PKG/plugins/$NAME/$F" "$PKG/codex/$NAME/$F"
done

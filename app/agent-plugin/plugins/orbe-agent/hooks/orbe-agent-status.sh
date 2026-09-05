#!/bin/sh
# Orbe エージェント状態報告のシム。各 CLI の hook から呼ばれ、.app 同梱の
# orbe-report（env ORBE_REPORT_BIN が指す絶対パス）へそのまま委譲する。
# Orbe のタブでのみ env が注入されるため、無ければ no-op（他端末では何もしない）。
#
# 使い方: orbe-agent-status.sh <agent> <state>
#   <agent> = claude | codex | agy
#   <state> = idle | working | waiting | done | clear
# stdin（hook JSON）は exec で透過し、orbe-report が session_id を抽出する。

[ -n "$ORBE_REPORT_BIN" ] || exit 0
# 自分と同じチャネルのタブからの呼び出しにだけ応える。dev / release の plugin は別名の別枠として
# 両方 enabled になり、CLI は有効な全 plugin の hook を全セッションで走らせるため。channel は実体化時に
# Orbe が刻んだ自分の bundle ID、ORBE_BUNDLE_ID はタブを開いた Orbe が名乗る bundle ID。
# $0 からの相対で引くのは、claude / codex が絶対パスで呼び agy は cwd＝ステージ済みプラグインルート
# からの相対で呼ぶため。判定材料が片方でも欠けたら通す（状態追跡を黙って殺さない）。
CHANNEL_FILE="$(dirname "$0")/channel"
if [ -n "$ORBE_BUNDLE_ID" ] && [ -r "$CHANNEL_FILE" ]; then
  read -r OWNER < "$CHANNEL_FILE"
  [ "$OWNER" = "$ORBE_BUNDLE_ID" ] || exit 0
fi
exec "$ORBE_REPORT_BIN" "$@"

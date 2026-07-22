#!/bin/sh
# Orbe エージェント状態報告のシム。各 CLI の hook から呼ばれ、.app 同梱の
# orbe-report（env ORBE_REPORT_BIN が指す絶対パス）へそのまま委譲する。
# Orbe 内ペインでのみ env が注入されるため、無ければ no-op（他端末では何もしない）。
#
# 使い方: orbe-agent-status.sh <agent> <state>
#   <agent> = claude | codex | agy
#   <state> = idle | working | waiting | done | clear
# stdin（hook JSON）は exec で透過し、orbe-report が session_id を抽出する。

[ -n "$ORBE_REPORT_BIN" ] || exit 0
exec "$ORBE_REPORT_BIN" "$@"

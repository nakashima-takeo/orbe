#!/usr/bin/env bash
# 振る舞いの視覚確認: 本物のアクションを呼んで生んだ状態を連番 PNG（フィルムストリップ）化して開く。
# .app 起動も Peekaboo も不要。fixture（preview-gallery.sh）と違い、アクションの回帰を画で拾う。
#
#   引数なし          → 全 flow を撮る（クラス全体）
#   引数（flow 名）   → その 1 本だけ撮る（例: palette_drill）
set -euo pipefail
cd "$(dirname "$0")/.."

# 有効な flow 名（= テストメソッドの担当 flow）。snake_case のまま PNG 接頭辞でもある。
FLOWS="palette_nav palette_drill settings_palette settings_palette_override settings_palette_worktree settings_palette_worktree_narrow settings_palette_agent_empty onboarding_install completion_scroll workspace_filter workspace_rename workspace_overflow update_states"

# flow 名 → テストメソッド名（snake_case を test + PascalCase へ）。BSD/GNU 両対応で awk のみで変換。
to_method() {
  printf '%s\n' "$1" | awk '{
    n = split($0, p, "_"); out = "test"
    for (i = 1; i <= n; i++) out = out toupper(substr(p[i], 1, 1)) substr(p[i], 2)
    print out
  }'
}

usage() {
  echo "usage: $(basename "$0") [flow_name]" >&2
  echo "  引数なし: 全 flow を撮る。flow 名を渡すとその 1 本だけ撮る。" >&2
  echo "  有効な flow 名:" >&2
  for f in $FLOWS; do echo "    $f" >&2; done
}

run() {
  ORBE_FLOWS=1 swift test --filter "$1" 2>&1 \
    | grep -E "\[flow\] wrote|passed|failed|error:" || true
}

if [[ $# -eq 0 ]]; then
  run "DesignFlowSnapshotTests"  # クラス全体 = 全 flow
  open .preview/flows
  exit 0
fi

flow="$1"
for f in $FLOWS; do
  if [[ "$f" == "$flow" ]]; then
    run "DesignFlowSnapshotTests/$(to_method "$flow")"
    open .preview/flows/"${flow}"_*.png
    exit 0
  fi
done

echo "error: unknown flow '$flow'" >&2
usage
exit 1

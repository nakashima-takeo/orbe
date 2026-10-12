import Foundation

/// 秘書の係（行き先の段の ⌘↵・行の ⌘↵・最初の入力）と、タスクから作業を始める（`start_task`）の文言分冊。
/// 本体 `L10n.table` が結合する。
extension L10n {
  static let secretaryTable: [L10nKey: (ja: String, en: String)] = [
    .taskStartHomeTask: (
      "タスク %1$@「%2$@」に取り掛かってください。詳細は Orbe の MCP（list_tasks）で読む。",
      "Work on task %1$@ “%2$@”. Read its details with Orbe’s MCP (list_tasks)."
    ),
    .secretaryAutomationFixInput: (
      "タスクの自動追加 %1$@「%2$@」を直す。", "Fix task auto-add %1$@ “%2$@”."
    ),
    .taskPaletteDestination: ("行き先", "Destination"),
    .taskPaletteDestinationTask: ("タスクに書く", "Write a task"),
    .taskPaletteDestinationDefault: ("既定", "default"),
    .taskPaletteHandToAgent: ("agent に任せる", "Hand to an agent"),
    .taskPaletteHintOpenAgent: ("agent を開く", "Open agent"),
    .taskPaletteDestinationNoWorkspace: ("workspace なし", "no workspace"),
    .taskPaletteErrSecretaryClaude: (
      "claude が見つからないので agent に任せられない", "Can’t hand to an agent: claude was not found"
    ),
    .taskPaletteErrSecretaryUnavailable: ("agent を起こせなかった", "Couldn’t start an agent"),
  ]
}

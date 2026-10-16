import Foundation

/// 秘書の係（入力欄の中の「⌘↵ agent に任せる」・行の ⌘↵・最初の入力）と、タスクから作業を始める（`start_task`）の文言分冊。
/// 本体 `L10n.table` が結合する。
extension L10n {
  static let secretaryTable: [L10nKey: (ja: String, en: String)] = [
    .taskStartHomeTask: (
      "タスク %1$@「%2$@」に取り掛かってください。詳細は Orbe の MCP（list_tasks）で読む。",
      "Work on task %1$@ “%2$@”. Read its details with Orbe’s MCP (list_tasks)."
    ),
    .secretaryRequestInput: ("依頼: %@", "Request: %@"),
    .secretaryAutomationFixInput: ("自動化 %1$@「%2$@」を直す。", "Fix automation %1$@ “%2$@”."),
    .taskPaletteAddToTasks: ("タスクに追加", "Add a task"),
    .taskPaletteHandToAgent: ("agent に任せる", "Hand to an agent"),
    .taskPaletteHintOpenAgent: ("agent を開く", "Open agent"),
    .taskPaletteErrSecretaryClaude: (
      "claude が見つからないので agent に任せられない", "Can’t hand to an agent: claude was not found"
    ),
    .taskPaletteErrSecretaryUnavailable: ("agent を起動できなかった", "Couldn’t start an agent"),
  ]
}

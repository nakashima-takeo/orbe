import Foundation

/// 秘書（行き先の段の ⌘↵・頼む欄・頼みの文面・応えない知らせ）と、タスクから作業を始める（`start_task`）の文言分冊。
/// 本体 `L10n.table` が結合する。
extension L10n {
  static let secretaryTable: [L10nKey: (ja: String, en: String)] = [
    .taskStartHomeTask: (
      "タスク %1$@「%2$@」に取り掛かってください。詳細は Orbe の MCP（list_tasks）で読む。",
      "Work on task %1$@ “%2$@”. Read its details with Orbe’s MCP (list_tasks)."
    ),
    .secretaryLineOrigin: ("⌘⇧X から · %@", "From ⌘⇧X · %@"),
    .secretaryLineWaitOrigin: ("待ちの条件 · %@", "Wait condition · %@"),
    .secretaryLineTask: ("タスク %1$@「%2$@」を頼む。", "Task %1$@ “%2$@”: please take it on."),
    .secretaryLineLinkedTask: (
      "タスク %1$@「%2$@」(%3$@) を頼む。", "Task %1$@ “%2$@” (%3$@): please take it on."
    ),
    .secretaryLineNote: ("補足: %@", " Note: %@"),
    .secretaryUnresponsive: (
      "秘書が応答しない — タブで確かめる", "The secretary isn’t responding — check its tab"
    ),
    .taskPaletteDestination: ("行き先", "Destination"),
    .taskPaletteDestinationTask: ("タスクに書く", "Write a task"),
    .taskPaletteDestinationDefault: ("既定", "default"),
    .taskPaletteAskSecretary: ("秘書に頼む", "Ask the secretary"),
    .taskPaletteDestinationPlace: ("%1$@ · %2$@の先頭 · %3$@", "%1$@ · top of %2$@ · %3$@"),
    .taskPaletteDestinationNoWorkspace: ("workspace なし", "no workspace"),
    .taskPaletteAskTitle: ("%1$@ を秘書に頼む", "Ask the secretary about %1$@"),
    .taskPaletteAskOptional: ("補足は無くてもよい", "A note is optional"),
    .taskPaletteAskScope: (
      "秘書はこのタスクを対象に動く。新しいタスクは作らない", "The secretary works on this task and won’t create a new one"
    ),
    .taskPaletteAskAfter: (
      "頼んだ後は、秘書が起こした agent がこの行に出る", "Once asked, the agent the secretary starts shows on this row"
    ),
    .taskPaletteHintStopAsking: ("やめる", "Cancel"),
    .taskPaletteAsked: ("秘書に頼んだ", "Asked the secretary"),
    .taskPaletteAskedQueued: (
      "秘書に頼んだ — 手が空いたら届く", "Asked the secretary — it arrives when the secretary is free"
    ),
    .taskPaletteErrSecretaryClaude: (
      "claude が見つからないので秘書に頼めない", "Can’t ask the secretary: claude was not found"
    ),
    .taskPaletteAskHandOver: ("このタスクを渡す", "Hand this task over"),
  ]
}

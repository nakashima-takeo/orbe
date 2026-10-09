import Foundation

/// 秘書（⌘⇧X の ⌘↵・頼む欄・頼みの文面）と、タスクから作業を始める（`start_task`）の文言分冊。
/// 本体 `L10n.table` が結合する。
extension L10n {
  static let secretaryTable: [L10nKey: (ja: String, en: String)] = [
    .taskStartHomeTask: ("タスク %1$@「%2$@」に取り掛かってください。", "Work on task %1$@ “%2$@”."),
    .taskStartHomeDescription: ("詳細:", "Details:"),
    .secretaryLineOrigin: ("⌘⇧X から · %@", "From ⌘⇧X · %@"),
    .secretaryLineTask: ("タスク %1$@「%2$@」を頼む。", "Task %1$@ “%2$@”: please take it on."),
    .secretaryLineLinkedTask: (
      "タスク %1$@「%2$@」(%3$@) を頼む。", "Task %1$@ “%2$@” (%3$@): please take it on."
    ),
    .secretaryLineNote: ("補足: %@", " Note: %@"),
  ]
}

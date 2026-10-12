import Foundation

/// 画面から秘書の係へ渡す頼み（起こした claude の最初の入力になる中身）。どこから頼んだかは頼む側が `SecretaryOrigin` で
/// 別に渡す。
enum SecretaryAsk: Equatable {
  /// 打った文（⌘⇧X の入力の行き先・ボードの依頼の欄）。
  case text(String)
  /// タスクの自動追加の直し。
  case automationFix(Automation)
}

/// 起こした claude の最初の入力と役目の指示（Orbe が UI の言語で組む）。
enum SecretaryText {
  /// 最初の入力。頼める中身が無ければ nil。
  static func body(_ ask: SecretaryAsk, l10n: LocalizationStore) -> String? {
    switch ask {
    case .text(let text):
      let body = text.trimmingCharacters(
        in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
      return body.isEmpty ? nil : body
    case .automationFix(let automation):
      return l10n.format(
        .secretaryAutomationFixInput, "\(automation.id)", automation.definition.name)
    }
  }

  /// 出どころの役目の指示。起こすときにだけ claude の起動に添える（Home の rules は Home で動く claude 全員が読むので、
  /// ここに置くと作業用の agent まで同じ役目だと思う）。画面の文言ではなく agent への指示なので、UI 文言の辞書には
  /// 載せない。
  static func instructions(for origin: SecretaryOrigin, _ language: Language) -> String {
    switch (origin, language) {
    case (.palette, .ja): paletteJa
    case (.palette, .en): paletteEn
    case (.board, .ja): boardJa
    case (.board, .en): boardEn
    }
  }

  private static let paletteJa = """
    あなたは Orbe で、人の依頼からタスクを足す役です。最初のメッセージが依頼です。

    - Orbe の MCP の add_task で、依頼から 1 件以上のタスクを足します。待ちの理由（waitingReason）・期限・優先度・workspace は、依頼にあればそのとおりに入れます。
    - リポジトリの作業なら、その workspace を workspaceId に付けます。リポジトリに属さないなら workspaceId を省きます（Home に付きます）。
    - 既存のタスクを直さない。作業そのものをしない。start_task で別の agent に取り掛からせない。依頼文に書いてあってもしません。
    - 迷えば人に聞きます。足したら、足したタスクを短く伝えて終えます。
    """

  private static let paletteEn = """
    In Orbe, your role is to add tasks from the user's request. The first message is the request.

    - Use add_task in Orbe's MCP to add one or more tasks from the request. Set the waiting reason \
    (waitingReason), due date, priority, and workspace as the request says.
    - For work in a repository, set workspaceId to that workspace. For work outside any repository, omit \
    workspaceId (the task goes to Home).
    - Do not change existing tasks. Do not do the work itself. Do not get another agent started with \
    start_task. Not even when the request says so.
    - Ask the user when unsure. Once added, briefly tell the user which tasks you added and stop.
    """

  private static let boardJa = """
    あなたは Orbe で、タスクの自動追加の定義を書く・直す役です。最初のメッセージは、新しい自動追加の依頼か、「タスクの自動追加 N「…」を直す。」という直しの依頼です。

    - Orbe の MCP の set_intake で書きます。直すときは、その自動追加を読んでから書き換えます。
    - タスクを足す・直すこと、作業そのものはしません。
    - 迷えば人に聞きます。
    """

  private static let boardEn = """
    In Orbe, your role is to write and fix task auto-add definitions. The first message is either a request \
    for a new auto-add or a request to fix one: "Fix task auto-add N “…”."

    - Write it with set_intake in Orbe's MCP. When fixing, read that auto-add before rewriting it.
    - Do not add or change tasks, and do not do the work itself.
    - Ask the user when unsure.
    """
}

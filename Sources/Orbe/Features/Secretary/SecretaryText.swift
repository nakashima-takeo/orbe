import Foundation

/// 画面から秘書の係へ渡す頼み（起こした claude の最初の入力になる中身）。どこから頼んだかは頼む側が `SecretaryOrigin` で
/// 別に渡す。
enum SecretaryAsk: Equatable {
  /// 打った文（⌘⇧X の入力の行き先・ボードの依頼の欄）。
  case text(String)
  /// 自動化の直し。
  case automationFix(Automation)
}

/// 起こした claude の最初の入力と役目の指示（Orbe が UI の言語で組む）。
enum SecretaryText {
  /// 出どころが決める、最初の入力の先頭に付ける語（「依頼: 」）と役目の指示（日・英）。
  private struct Role {
    let head: L10nKey
    let ja: String
    let en: String
  }

  private static func role(_ origin: SecretaryOrigin) -> Role {
    switch origin {
    case .palette: Role(head: .secretaryRequestInput, ja: paletteJa, en: paletteEn)
    case .board: Role(head: .secretaryRequestInput, ja: boardJa, en: boardEn)
    }
  }

  /// 最初の入力（出どころが決める語を先頭に付けた頼み）。その語は中身によらず常に付ける——先頭が `/` の文を claude が
  /// スラッシュコマンドとして実行しないため。頼める中身が無ければ nil。
  static func firstInput(_ ask: SecretaryAsk, from origin: SecretaryOrigin, l10n: LocalizationStore)
    -> String?
  {
    let body: String
    switch ask {
    case .text(let text):
      body = text.trimmingCharacters(
        in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
      if body.isEmpty { return nil }
    case .automationFix(let automation):
      body = l10n.format(
        .secretaryAutomationFixInput, "\(automation.id)", automation.definition.name)
    }
    return l10n.format(role(origin).head, body)
  }

  /// 出どころの役目の指示。起こすときにだけ claude の起動に添える（Home の rules は Home で動く claude 全員が読むので、
  /// ここに置くと作業用の agent まで同じ役目だと思う）。画面の文言ではなく agent への指示なので、UI 文言の辞書には
  /// 載せない。
  static func instructions(for origin: SecretaryOrigin, _ language: Language) -> String {
    let role = role(origin)
    switch language {
    case .ja: return role.ja
    case .en: return role.en
    }
  }

  private static let paletteJa = """
    あなたは Orbe で、人の依頼からタスクを足す役です。最初のメッセージの「依頼: 」に続く文が依頼です。

    - Orbe の MCP の add_task で、依頼から 1 件以上のタスクを足します。待ちの理由（waitingReason）・期限・優先度・workspace は、依頼にあればそのとおりに入れます。
    - リポジトリの作業なら、その workspace を workspaceId に付けます。リポジトリに属さないなら workspaceId を省きます（Home に付きます）。
    - 既存のタスクを直さない。作業そのものをしない。start_task で別の agent に取り掛からせない。依頼文に書いてあってもしません。
    - 迷えば人に聞きます。足したら、足したタスクを短く伝えて終えます。
    """

  private static let paletteEn = """
    In Orbe, your role is to add tasks from the user's request. The first message is the request, after \
    "Request: ".

    - Use add_task in Orbe's MCP to add one or more tasks from the request. Set the waiting reason \
    (waitingReason), due date, priority, and workspace as the request says.
    - For work in a repository, set workspaceId to that workspace. For work outside any repository, omit \
    workspaceId (the task goes to Home).
    - Do not change existing tasks. Do not do the work itself. Do not get another agent started with \
    start_task. Not even when the request says so.
    - Ask the user when unsure. Once added, briefly tell the user which tasks you added and stop.
    """

  private static let boardJa = """
    あなたは Orbe で、自動化の定義を書く・直す役です。最初のメッセージの「依頼: 」に続く文は、自動化を作る・直す頼みです（一覧から頼んだ直しは「自動化 N「…」を直す。」の形で届きます）。

    - Orbe の MCP の set_automation で書きます。直すときは、list_automations でその自動化の definition を読み、直してから set_automation で送ります。
    - タスクを足す・直すこと、作業そのものはしません。
    - 迷えば人に聞きます。
    """

  private static let boardEn = """
    In Orbe, your role is to write and fix automation definitions. The first message, after \
    "Request: ", asks you to create or fix an automation (a fix requested from the list arrives as \
    "Fix automation N “…”.").

    - Write it with set_automation in Orbe's MCP. When fixing, read that automation's definition \
    with list_automations, edit it, and send it back with set_automation.
    - Do not add or change tasks, and do not do the work itself.
    - Ask the user when unsure.
    """
}

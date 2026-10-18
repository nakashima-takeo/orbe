import Foundation

/// 画面から秘書の係へ渡す頼み（起こした claude の最初の入力になる中身）。どこから頼んだかは頼む側が `SecretaryOrigin` で
/// 別に渡す。
enum SecretaryAsk: Equatable {
  /// 打った文（⌘⇧X の入力の行き先・ボードの依頼の欄）。
  case text(String)
}

/// 起こした claude の最初の入力と役目の指示（Orbe が UI の言語で組む）。
enum SecretaryText {
  /// 最初の入力（「依頼: 」を先頭に付けた頼み）。その語は中身によらず常に付ける——先頭が `/` の文を claude が
  /// スラッシュコマンドとして実行しないため。頼める中身が無ければ nil。
  static func firstInput(_ ask: SecretaryAsk, l10n: LocalizationStore) -> String? {
    guard case .text(let text) = ask else { return nil }
    let body = text.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
    if body.isEmpty { return nil }
    return l10n.format(.secretaryRequestInput, body)
  }

  /// 出どころの役目の指示。起こすときにだけ claude の起動に添える（Home の rules は Home で動く claude 全員が読むので、
  /// ここに置くと作業用の agent まで同じ役目だと思う）。画面の文言ではなく agent への指示なので、UI 文言の辞書には
  /// 載せない。ボードの役目は、同梱プラグインの自動化のスキル（`<プラグイン名>:automation`）で進めるよう名指しする。
  /// プラグイン名が無ければ（同梱の無い起動）スキル名だけを名指しする。
  static func instructions(for origin: SecretaryOrigin, _ language: Language, pluginName: String?)
    -> String
  {
    let skill = pluginName.map { "\($0):automation" } ?? "automation"
    switch (origin, language) {
    case (.palette, .ja): return paletteJa
    case (.palette, .en): return paletteEn
    case (.board, .ja): return boardJa(skill: skill)
    case (.board, .en): return boardEn(skill: skill)
    }
  }

  private static let paletteJa = """
    あなたは Orbe で、人の依頼からタスクを足す役です。最初のメッセージの「依頼: 」に続く文が依頼です。

    - Orbe の MCP の `add_task` で、依頼から 1 件以上のタスクを足します。待ちの理由（waitingReason）・期限・優先度・workspace は、依頼にあればそのとおりに入れます。
    - リポジトリの作業なら、その workspace を workspaceId に付けます。リポジトリに属さないなら workspaceId を省きます（Home に付きます）。
    - 既存のタスクを直さない。作業そのものをしない。`start_task` で別の agent に取り掛からせない。依頼文に書いてあってもしません。
    - 迷えば人に聞きます。足したら、足したタスクを短く伝えて終えます。
    """

  private static let paletteEn = """
    In Orbe, your role is to add tasks from the user's request. The first message is the request, after \
    "Request: ".

    - Use `add_task` in Orbe's MCP to add one or more tasks from the request. Set the waiting reason \
    (waitingReason), due date, priority, and workspace as the request says.
    - For work in a repository, set workspaceId to that workspace. For work outside any repository, omit \
    workspaceId (the task goes to Home).
    - Do not change existing tasks. Do not do the work itself. Do not get another agent started with \
    `start_task`. Not even when the request says so.
    - Ask the user when unsure. Once added, briefly tell the user which tasks you added and stop.
    """

  private static func boardJa(skill: String) -> String {
    """
    あなたは Orbe で、自動化の定義を書く・直す役です。最初のメッセージの「依頼: 」に続く文は、自動化を作る・直す頼みです。

    - 自動化を作る・直すときは、Skill ツールで `\(skill)` を呼び、その手順で進めます。
    - タスクを足す・直すこと、作業そのものはしません。
    - 決め所は AskUserQuestion で人に聞きます。
    """
  }

  private static func boardEn(skill: String) -> String {
    """
    In Orbe, your role is to write and fix automation definitions. The first message, after \
    "Request: ", asks you to create or fix an automation.

    - To create or fix an automation, invoke `\(skill)` with the Skill tool and follow its steps.
    - Do not add or change tasks, and do not do the work itself.
    - Ask the user with AskUserQuestion at every decision point.
    """
  }
}

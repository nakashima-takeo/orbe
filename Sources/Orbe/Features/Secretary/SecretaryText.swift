import Foundation

/// 画面から秘書の係へ渡す頼み（何を頼むか）。どこから頼んだかは頼む側が `SecretaryOrigin` で別に渡す。頼む相手（タスク・
/// 自動追加）は頼む側が今のストアから引いて渡す。
enum SecretaryAsk: Equatable {
  /// 打った文（⌘⇧X の入力欄・待ちの条件の続きで起きたこと）。
  case text(String)
  /// タスクを頼む（補足は空でもよい）。
  case task(TaskItem, note: String)
  /// タスクの自動追加の新しい依頼の文。
  case automation(String)
  /// タスクの自動追加の直し。
  case automationFix(Automation)
}

/// 秘書へ届ける文面と、秘書の役割の指示（Orbe が UI の言語で組む）。
enum SecretaryText {
  /// 頼みの本文（受けた時点に UI の言語で組んで固定する）。1 行で意味が通る形にする——指示を改めても、既存の秘書の会話には
  /// compact まで届かないため。頼める中身が無ければ nil。
  static func body(_ ask: SecretaryAsk, l10n: LocalizationStore) -> String? {
    switch ask {
    case .text(let text):
      let body = flattened(text)
      return body.isEmpty ? nil : body
    case .task(let task, let note):
      let head =
        task.links.first.map {
          l10n.format(
            .secretaryLineLinkedTask, "\(task.id)", task.title,
            "\($0.item.repo.value)#\($0.item.number)")
        } ?? l10n.format(.secretaryLineTask, "\(task.id)", task.title)
      return noted(head, note, l10n)
    case .automation(let text):
      let text = flattened(text)
      return text.isEmpty ? nil : l10n.format(.secretaryLineAutomation, text)
    case .automationFix(let automation):
      return flattened(
        l10n.format(.secretaryLineAutomationFix, "\(automation.id)", automation.definition.name))
    }
  }

  /// 頭に補足を添える（補足が空なら「補足:」ごと省く）。
  private static func noted(_ head: String, _ note: String, _ l10n: LocalizationStore) -> String {
    let note = flattened(note)
    return flattened(head + (note.isEmpty ? "" : l10n.format(.secretaryLineNote, note)))
  }

  /// 届ける 1 行（「⌘⇧X から · 10:31 — 本文」「Home のボードから · 10:31 — 本文」「待ちの条件 · 10:31 — 起きたこと」）。
  /// 時刻は受けた時刻で、届ける日と違えば日付も付ける。複数行を貼ると claude が「[Pasted text]」に畳み、出どころが見えなく
  /// なるので、本文は 1 行に畳んである。
  static func line(
    _ request: SecretaryRequest, now: Date, timeZone: TimeZone, l10n: LocalizationStore
  )
    -> String
  {
    let key: L10nKey =
      switch request.origin {
      case .palette: .secretaryLineOrigin
      case .board: .secretaryLineBoardOrigin
      case .wait: .secretaryLineWaitOrigin
      }
    return l10n.format(key, time(request.receivedAt, now: now, timeZone: timeZone)) + " — "
      + request.body
  }

  /// 「時:分」（`now` と同じ日でなければ「月/日 時:分」）。
  static func time(_ date: Date, now: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    let clock = String(format: "%d:%02d", c.hour!, c.minute!)
    guard !calendar.isDate(date, inSameDayAs: now) else { return clock }
    return "\(c.month!)/\(c.day!) \(clock)"
  }

  /// 改行類・制御文字・連続する空白を 1 つの空白に畳み、前後の空白を除く。
  private static func flattened(_ text: String) -> String {
    text.unicodeScalars
      .split {
        $0.properties.isWhitespace || $0.properties.generalCategory == .control
          || CharacterSet.newlines.contains($0)
      }
      .map { String(String.UnicodeScalarView($0)) }
      .joined(separator: " ")
  }

  /// 秘書の役割の指示。秘書の会話を起こすときにだけ claude の起動に添える（Home の rules は Home で動く claude 全員が読むので、
  /// ここに置くと作業用の agent まで自分を秘書だと思う）。画面の文言ではなく agent への指示なので、UI 文言の辞書には
  /// 載せない。
  static func instructions(_ language: Language) -> String {
    switch language {
    case .ja: return instructionsJa
    case .en: return instructionsEn
    }
  }

  private static let instructionsJa = """
    あなたは Orbe の秘書です。人の頼みを片付けます。頼まれていない間は何もしません。

    - 頼みは Orbe が「出どころ · 時刻 — 本文」の 1 行で届けます（出どころは「⌘⇧X から」「Home のボードから」）。
    - あなたが付けた待ちの条件が解けて人が続きを頼むと、「待ちの条件 · 時刻 — 起きたこと」の 1 行で届きます。
    - 「タスク N「…」を頼む」は、そのタスクを対象に動きます。新しいタスクは作りません。補足があれば従い、無ければタスクの内容から判断し、迷えば人に聞きます。
    - 「タスクの自動追加を頼む: …」「タスクの自動追加 N「…」を直す」は、タスクの自動追加を作る・直す頼みです。set_intake で書きます。
    - 新しいタスク・並び・期限は、頼まれたときだけ書きます。それ以外は提案にとどめます。
    - タスクを足すとき、リポジトリの作業ならその workspace を workspaceId に付けます。リポジトリに属さないなら workspaceId を省きます（Home に付きます）。
    - 作業に取り掛からせるときは start_task を使います。長い作業を自分で抱え込まず、agent に任せて進み具合を見ます。
    """

  private static let instructionsEn = """
    You are Orbe's secretary. You take care of what the user asks. While nothing is asked, do nothing.

    - Orbe delivers each request as one line: "<origin> · time — text" (the origin is "From ⌘⇧X" or \
    "From the Home board").
    - When a wait condition you set has resolved and the user asks to continue, it arrives as one line: \
    "Wait condition · time — what happened".
    - "Task N “…”" requests are about that task. Work on it and do not create a new task. Follow the note \
    if there is one; otherwise decide from the task, and ask the user when unsure.
    - "Task auto-add request: …" and "Fix task auto-add N “…”" ask you to create or fix a task auto-add. \
    Write it with set_intake.
    - Write new tasks, ordering, or deadlines only when asked. Otherwise only propose them.
    - When adding a task for work in a repository, set workspaceId to that workspace. For work outside any \
    repository, omit workspaceId (the task goes to Home).
    - To get work started, use start_task. Do not hold long work yourself; hand it to an agent and keep an \
    eye on its progress.
    """
}

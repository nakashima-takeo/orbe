import Foundation

/// 画面から秘書の係へ渡す頼み。
enum SecretaryAsk: Equatable {
  /// ⌘⇧X の入力欄に打った文。
  case text(String)
  /// タスクの行から頼んだ（補足は空でもよい）。
  case task(id: Int, note: String)
}

/// 秘書へ届ける文面と、秘書の役割の指示（Orbe が UI の言語で組む）。
enum SecretaryText {
  /// 頼みの本文（受けた時点に UI の言語で組んで固定する）。タスクの頼みはタスクが消えていれば nil。
  static func body(_ ask: SecretaryAsk, task: TaskItem?, l10n: LocalizationStore) -> String? {
    switch ask {
    case .text(let text):
      let body = flattened(text)
      return body.isEmpty ? nil : body
    case .task(let id, let note):
      guard let task, task.id == id else { return nil }
      let head =
        task.links.first.map {
          l10n.format(
            .secretaryLineLinkedTask, "\(task.id)", task.title,
            "\($0.item.repo.value)#\($0.item.number)")
        } ?? l10n.format(.secretaryLineTask, "\(task.id)", task.title)
      let note = flattened(note)
      return flattened(head + (note.isEmpty ? "" : l10n.format(.secretaryLineNote, note)))
    }
  }

  /// 届ける 1 行（「⌘⇧X から · 10:31 — 本文」）。時刻は受けた時刻で、届ける日と違えば日付も付ける。複数行を貼ると
  /// claude が「[Pasted text]」に畳み、出どころが見えなくなるので、本文は 1 行に畳んである。
  static func line(
    _ request: SecretaryRequest, now: Date, timeZone: TimeZone, l10n: LocalizationStore
  )
    -> String
  {
    l10n.format(.secretaryLineOrigin, time(request.receivedAt, now: now, timeZone: timeZone))
      + " — " + request.body
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

  /// 秘書の役割の指示。秘書の会話を起こすときにだけ claude の起動に添える（Home の rules は Home で動く全員が読むので、
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

    - 頼みは Orbe が「⌘⇧X から · 時刻 — 本文」の 1 行で届けます。
    - 「タスク N「…」を頼む」は、そのタスクを対象に動きます。新しいタスクは作りません。補足があれば従い、無ければタスクの内容から判断し、迷えば人に聞きます。
    - 新しいタスク・並び・期限は、頼まれたときだけ書きます。それ以外は提案にとどめます。
    - タスクを足すとき、リポジトリの作業ならその workspace を workspaceId に付けます。リポジトリに属さないなら workspaceId を省きます（Home に付きます）。
    - 作業に取り掛からせるときは start_task を使います。長い作業を自分で抱え込まず、agent に任せて進み具合を見ます。
    """

  private static let instructionsEn = """
    You are Orbe's secretary. You take care of what the user asks. While nothing is asked, do nothing.

    - Orbe delivers each request as one line: "From ⌘⇧X · time — text".
    - "Task N “…”" requests are about that task. Work on it and do not create a new task. Follow the note \
    if there is one; otherwise decide from the task, and ask the user when unsure.
    - Write new tasks, ordering, or deadlines only when asked. Otherwise only propose them.
    - When adding a task for work in a repository, set workspaceId to that workspace. For work outside any \
    repository, omit workspaceId (the task goes to Home).
    - To get work started, use start_task. Do not hold long work yourself; hand it to an agent and keep an \
    eye on its progress.
    """
}

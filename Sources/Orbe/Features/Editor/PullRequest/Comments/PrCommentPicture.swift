import AppKit
import OrbeEditorCore

/// スレッドと新しいコメントの欄の絵を組む（中身・状態・幅 → 絵の純関数）。
///
/// 箱は本文の区画の左端から始まり、右に 16、上に 4、下に 8 の空きを持つ（角丸 6・枠 1・影 0 10 30）。開いたスレッドは、頭（高さ
/// 26 と下縁 1。上の 2 角だけ丸い。「行 N」（範囲なら「行 N〜M」）・状態・「解決」・「折りたたむ」）・コメントの列（アバターの
/// 頭文字の円・書いた人と時刻と未送信の札・本文）・返信の行（返信欄・「レビューに追加」・「解決して返信」）・失敗の文。畳んだ
/// スレッドは頭の帯だけ（4 角とも丸い）で、「行 N」の後に最初のコメントの書いた人と本文の先頭 1 行を出す。新しいコメントの欄は、
/// 箱から頭とコメントの列を除いた形（返信欄・「レビューに追加」・「取り消す」）で、範囲の欄だけ、箱の中の最初の行（高さ 26）に
/// 「N〜M 行にコメント」を出す。書き込めない間（欄の行を移している・行が現在の diff に無い）は「レビューに追加」を押せない
/// 姿にする。置き場所の文（→ `PrCommentNotice`）は失敗の文の上に出す。
@MainActor
enum PrCommentPicture {
  /// 中身の外の状態（付いた行の範囲・ホバー・書き込みの最中・入力欄が主か・失敗の文・置き場所の文・書き込めるか・入力欄に字が
  /// あるか・文言の言語）。
  struct State {
    let lines: GitHubLineRange
    let hovered: PrCommentControl?
    let isWriting: Bool
    let isFieldPrimary: Bool
    let failure: String?
    let notice: PrCommentNotice?
    /// 書き込める（→ `PrCommentZone.canSend`）と、入力欄に空白と改行のほかの字がある。
    let canSend: Bool
    let hasText: Bool
    let language: Language
  }

  /// 組んだ絵と、その絵のリンクの行き先（コメントの id → 本文の層の中の通し番号 → URL）と、開いたスレッドのコメントごとの
  /// 縦の範囲（コメントの id → 絵の座標の上端〜下端）。
  struct Composed {
    let picture: ZonePicture
    let links: [String: [Int: URL]]
    var comments: [String: Range<CGFloat>] = [:]
  }

  /// 頭の帯の敷き方。
  enum Head {
    /// 箱の上端に高さ 26 の帯と下縁 1（上の 2 角だけ丸い）。
    case top
    /// 箱の中の全体が帯（4 角とも丸い・下縁なし）。
    case whole
  }

  private typealias Size = Theme.Layout

  /// 箱の最小の幅。
  private static let minimumWidth: CGFloat = 240

  /// 幅 `width`（本文の区画の幅）の箱の矩形（高さは 0）。
  private static func box(_ width: CGFloat) -> CGRect {
    CGRect(
      x: 0, y: Size.editorPrThreadTop, width: max(minimumWidth, width - Size.editorPrThreadRight),
      height: 0)
  }

  /// 幅 `width` のスレッドの本文の幅（箱の枠と左右の余白、アバターとその後の空きを除く）。
  static func bodyWidth(_ width: CGFloat) -> CGFloat {
    bodyWidth(of: box(width))
  }

  /// 箱 `frame` の本文の幅。
  static func bodyWidth(of frame: CGRect) -> CGFloat {
    frame.width - 2 - Size.editorPrThreadPadX * 2 - Size.editorPrThreadAvatar
      - Size.editorPrThreadAvatarGap
  }

  // MARK: - 開いたスレッド

  static func expanded(
    _ thread: GitHubPullRequestReview.Thread, bodies: [String: PrCommentBody],
    field: ZoneTextField, _ state: State, width: CGFloat
  ) -> Composed {
    var canvas = PrCommentCanvas(state: state)
    let frame = box(width)
    var y = frame.minY + 1
    header(thread, collapsed: false, in: frame, top: y, &canvas)
    y += Size.editorPrThreadHead + 1 + Size.editorPrThreadListPadY
    var spans: [String: Range<CGFloat>] = [:]
    for (index, comment) in thread.comments.enumerated() {
      if index > 0 { y += Size.editorPrThreadCommentGap }
      let top = y
      y += self.comment(comment, bodies[comment.id], in: frame, top: y, &canvas)
      spans[comment.id] = top..<y
    }
    y += Size.editorPrThreadListPadY
    if thread.canReply {
      let resolves = !thread.isResolved && thread.canResolve
      y += reply(
        field, buttons: resolves ? [.add, .resolveReply] : [.add], in: frame, top: y, &canvas)
      y += Size.editorPrThreadListPadY
    }
    y += notice(in: frame, top: y, &canvas)
    y += failure(in: frame, top: y, &canvas)
    var composed = canvas.finish(frame, bottom: y + 1, head: .top)
    composed.comments = spans
    return composed
  }

  // MARK: - 畳んだスレッド

  static func collapsed(_ thread: GitHubPullRequestReview.Thread, _ state: State, width: CGFloat)
    -> Composed
  {
    var canvas = PrCommentCanvas(state: state)
    let frame = box(width)
    let top = frame.minY + 1
    let right = header(thread, collapsed: true, in: frame, top: top, &canvas)
    if let first = thread.comments.first {
      let font = Theme.Typography.editorPrThreadHead
      let left =
        frame.minX + 1 + Size.editorPrThreadPadX
        + PrCommentStyle.width(lineLabel(state), font) + Size.editorPrThreadGap
      let summary = [first.author, firstLine(first.body)].compactMap { $0 }.joined(separator: " ")
      canvas.label(
        truncated(summary, font: font, width: right - Size.editorPrThreadGap - left), font: font,
        color: Theme.Color.textMuted, x: left,
        baseline: PrCommentStyle.baseline(top: top, height: Size.editorPrThreadHead, font: font))
    }
    return canvas.finish(frame, bottom: top + Size.editorPrThreadHead + 1, head: .whole)
  }

  // MARK: - 新しいコメントの欄

  static func draft(field: ZoneTextField, _ state: State, width: CGFloat) -> Composed {
    var canvas = PrCommentCanvas(state: state)
    let frame = box(width)
    var y = frame.minY + 1
    if state.lines.start != nil {
      let font = Theme.Typography.editorPrThreadHead
      canvas.label(
        draftLabel(state), font: font, color: Theme.Color.accentBright,
        x: frame.minX + 1 + Size.editorPrThreadPadX,
        baseline: PrCommentStyle.baseline(top: y, height: Size.editorPrThreadHead, font: font))
      y += Size.editorPrThreadHead
    } else {
      y += Size.editorPrThreadListPadY
    }
    y += reply(field, buttons: [.add, .cancel], in: frame, top: y, &canvas)
    y += Size.editorPrThreadListPadY
    y += notice(in: frame, top: y, &canvas)
    y += failure(in: frame, top: y, &canvas)
    return canvas.finish(frame, bottom: y + 1, head: nil)
  }

  // MARK: - 文言

  /// スレッドの頭の「行 N」（範囲なら「行 N〜M」。側をまたげば、差分の記号を付けて「行 −N〜+M」）。
  static func lineLabel(_ state: State) -> String {
    guard state.lines.start != nil else {
      return L10n.format(.editorPrThreadLine, state.language, state.lines.end.line)
    }
    let (start, end) = ends(state.lines)
    return L10n.format(.editorPrThreadLines, state.language, start, end)
  }

  /// 範囲の新しいコメントの欄の頭の「N〜M 行にコメント」（側をまたげば「−N〜+M 行にコメント」）。
  static func draftLabel(_ state: State) -> String {
    let (start, end) = ends(state.lines)
    return L10n.format(.editorPrDraftLines, state.language, start, end)
  }

  /// 範囲の両端の行の番号の文言（側をまたげば、差分の記号 − ＋ を付ける）。
  private static func ends(_ lines: GitHubLineRange) -> (String, String) {
    let start = lines.start ?? lines.end
    guard start.side != lines.end.side else { return ("\(start.line)", "\(lines.end.line)") }
    let signed = { (line: GitHubLine) in (line.side == .old ? "−" : "+") + "\(line.line)" }
    return (signed(start), signed(lines.end))
  }

  /// アバターの頭文字（login の先頭 2 字。消えたアカウントは「?」）。
  static func initials(_ author: String?) -> String {
    guard let author, !author.isEmpty else { return "?" }
    return String(author.prefix(2))
  }

  /// 本文の先頭の、空でない 1 行（長ければ先頭だけ）。読む字は、最初の空白でない字までと、その行の上限の字（Unicode の
  /// スカラー）の数まで（畳んだスレッドの描き直しの仕事が本文の長さに依らない——結合記号を続けた 1 字でも組む字が増えない）。
  static func firstLine(_ body: String) -> String {
    guard let text = body.firstIndex(where: { !$0.isWhitespace }) else { return "" }
    let start =
      body[..<text].lastIndex(where: \.isNewline).map(body.index(after:)) ?? body.startIndex
    let line = body[start...].prefix(summaryLimit).prefix { !$0.isNewline }
    return String(String.UnicodeScalarView(line.unicodeScalars.prefix(summaryLimit)))
  }

  /// 畳んだ頭に出す本文の先頭の、字（Unicode のスカラー）の数の上限（組む字を本文の長さに依らず抑える）。
  private static let summaryLimit = 200

  /// `string` が幅 `width` に収まらなければ、収まる所で切って「…」を付ける。
  static func truncated(_ string: String, font: NSFont, width: CGFloat) -> String {
    guard width > 0 else { return "" }
    let line = ZoneTextLayout.line([ZoneTextRun(string, font: font, color: .black)])
    guard line.width > width else { return string }
    let ellipsis = "…"
    let end = line.offset(atX: max(0, width - PrCommentStyle.width(ellipsis, font)))
    let utf16 = string.utf16
    let index = utf16.index(utf16.startIndex, offsetBy: end)
    return String(string[..<index]) + ellipsis
  }
}

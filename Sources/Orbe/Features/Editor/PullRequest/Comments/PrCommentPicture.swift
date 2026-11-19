import AppKit
import OrbeEditorCore

/// スレッドと新しいコメントの欄の絵を組む（中身・状態・幅 → 絵の純関数。寸法と色は見本 DiffView の Thread）。
///
/// 箱は本文の区画の左端から始まり、右に 16、上に 4、下に 8 の空きを持つ（角丸 6・枠 1・影 0 10 30）。開いたスレッドは、頭（高さ
/// 26 と下縁 1。上の 2 角だけ丸い。「行 N」・状態・「解決」・「折りたたむ」）・コメントの列（アバターの頭文字の円・書いた人と
/// 時刻と保留中の札・本文）・返信の行（返信欄・「レビューに追加」・「解決して返信」）・失敗の文。畳んだスレッドは頭の帯だけ
/// （4 角とも丸い）で、「行 N」の後に最初のコメントの書いた人と本文の先頭 1 行を出す。新しいコメントの欄は、箱から頭と
/// コメントの列を除いた形（返信欄・「レビューに追加」・「取り消す」）で、欄の行が現在の diff に無ければ「レビューに追加」を
/// 押せない姿にし、その旨の文を失敗の文の上に出す。欄の行を新しい版へ移している間も「レビューに追加」を押せない姿にする。
@MainActor
enum PrCommentPicture {
  /// 中身の外の状態（付いた行・ホバー・書き込みの最中・入力欄が主か・失敗の文・欄の行が現在の diff に無いか・欄の行を移しているか・文言の言語）。
  struct State {
    let line: Int
    let hovered: PrCommentControl?
    let isWriting: Bool
    let isFieldPrimary: Bool
    let failure: String?
    let isLineGone: Bool
    let isLineMoving: Bool
    let language: Language

    /// 書き込める——欄の行が現在の diff にあり、移している最中でない。
    var canSend: Bool { !isLineGone && !isLineMoving }
  }

  /// 組んだ絵と、その絵のリンクの行き先（押せる場所の通し番号 → URL）。
  struct Composed {
    let picture: ZonePicture
    let links: [Int: URL]
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
    _ thread: GitHubPullRequestReview.Thread, measured: [String: PrCommentMeasure],
    field: ZoneTextField, _ state: State, width: CGFloat
  ) -> Composed {
    var canvas = PrCommentCanvas(state: state)
    let frame = box(width)
    var y = frame.minY + 1
    header(thread, collapsed: false, in: frame, top: y, &canvas)
    y += Size.editorPrThreadHead + 1 + Size.editorPrThreadListPadY
    for (index, comment) in thread.comments.enumerated() {
      if index > 0 { y += Size.editorPrThreadCommentGap }
      y += self.comment(comment, measured[comment.id], in: frame, top: y, &canvas)
    }
    y += Size.editorPrThreadListPadY
    if thread.canReply {
      let resolves = !thread.isResolved && thread.canResolve
      y += reply(
        field, buttons: resolves ? [.add, .resolveReply] : [.add], in: frame, top: y, &canvas)
      y += Size.editorPrThreadListPadY
    }
    y += lineGone(in: frame, top: y, &canvas)
    y += failure(in: frame, top: y, &canvas)
    return canvas.finish(frame, bottom: y + 1, head: .top)
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
    var y = frame.minY + 1 + Size.editorPrThreadListPadY
    y += reply(field, buttons: [.add, .cancel], in: frame, top: y, &canvas)
    y += Size.editorPrThreadListPadY
    y += lineGone(in: frame, top: y, &canvas)
    y += failure(in: frame, top: y, &canvas)
    return canvas.finish(frame, bottom: y + 1, head: nil)
  }

  // MARK: - 文言

  static func lineLabel(_ state: State) -> String {
    L10n.format(.editorPrThreadLine, state.language, state.line)
  }

  /// アバターの頭文字（login の先頭 2 字。消えたアカウントは「?」）。
  static func initials(_ author: String?) -> String {
    guard let author, !author.isEmpty else { return "?" }
    return String(author.prefix(2))
  }

  /// 本文の先頭の、空でない 1 行（長ければ先頭だけ）。
  static func firstLine(_ body: String) -> String {
    let line = body.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
    return String((line ?? "").prefix(summaryLimit))
  }

  /// 畳んだ頭に出す本文の先頭の、字の数の上限（組む字を本文の長さに依らず抑える）。
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

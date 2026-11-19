import AppKit
import OrbeEditorCore

/// スレッドと新しいコメントの欄の押せる場所。
enum PrCommentControl: Hashable {
  /// 頭の「解決」「解決を取り消す」。
  case resolve
  /// 頭の「折りたたむ」「展開」。
  case collapse
  /// 「レビューに追加」。
  case add
  /// 「解決して返信」。
  case resolveReply
  /// 新しいコメントの欄の「取り消す」。
  case cancel
  /// 本文のリンク（組んだ絵の中の通し番号）。
  case link(Int)
}

/// diff の行の下に置く、スレッド 1 つか新しいコメントの欄 1 つの絵の差し込み。中身（スレッドの値・書き込みの最中か・失敗の文・
/// 畳んでいるか・ホバー）は載せる層が置き、変われば描き直させる。絵は `PrCommentPicture` が中身と幅から組む。本文の測りは
/// 裏で行い、幅ごとに覚える（→ `PrCommentMeasures`）。返信・新しいコメントの本文は入力欄（`field`）が持ち、描き直し・並びの
/// 置き直し・インライン ⇄ 並列をまたいで残る。
@MainActor
final class PrCommentZone: SurfaceZone {
  enum Subject: Equatable {
    case thread(GitHubPullRequestReview.Thread)
    /// 新しいコメントの欄。
    case draft
  }

  let field: ZoneTextField
  private(set) var subject: Subject
  /// 付いた行（その側の版の行。1 始まり）。
  var line: Int {
    didSet { if line != oldValue { redraw() } }
  }
  /// 描き直させる面（並びに置いた面。並びを置くたびに置き直す）。
  weak var surface: (any TextSurface)?
  /// 押せる場所が押された。
  var onPress: (PrCommentZone, PrCommentControl) -> Void = { _, _ in }
  /// 入力欄が主になった・外れた。
  var onFieldFocus: (PrCommentZone, Bool) -> Void = { _, _ in }

  var isCollapsed = false {
    didSet { if isCollapsed != oldValue { redraw() } }
  }
  /// 書き込みの最中（ボタンと欄を押せない姿にする）。
  var isWriting = false {
    didSet { if isWriting != oldValue { redraw() } }
  }
  /// 最後の書き込みの失敗の文（次の書き込みを始めたら消す）。
  var failure: String? {
    didSet { if failure != oldValue { redraw() } }
  }
  /// 新しいコメントの欄の行が現在の diff に無い（「レビューに追加」を押せない姿にし、その旨の文を出す）。
  var isLineGone = false {
    didSet { if isLineGone != oldValue { redraw() } }
  }
  /// 新しいコメントの欄の行を新しい版へ移している（「レビューに追加」を押せない姿にする）。
  var isLineMoving = false {
    didSet { if isLineMoving != oldValue { redraw() } }
  }
  var language: Language = .systemDefault {
    didSet { if language != oldValue { redraw() } }
  }
  private(set) var hovered: PrCommentControl?
  private(set) var isFieldPrimary = false
  /// 最後に組んだ絵のリンクの行き先。
  private var links: [Int: URL] = [:]
  private let measures = PrCommentMeasures()
  /// 入力欄の行の数と、空か（変わったときだけ描き直す）。
  private var fieldShape: (lines: Int, empty: Bool)

  init(subject: Subject, line: Int, fieldID: String) {
    self.subject = subject
    self.line = line
    field = ZoneTextField(id: fieldID, style: PrCommentStyle.field)
    fieldShape = (1, true)
    field.didChange = { [weak self] field in self?.fieldDidChange(field) }
    field.didChangePrimary = { [weak self] _, primary in
      guard let self else { return }
      isFieldPrimary = primary
      redraw()
      onFieldFocus(self, primary)
    }
    field.didSubmit = { [weak self] _ in
      guard let self else { return }
      onPress(self, .add)
    }
    measures.done = { [weak self] in self?.redraw() }
  }

  /// スレッドの値を置き換える（中身が変われば描き直す）。
  func update(_ subject: Subject) {
    guard subject != self.subject else { return }
    self.subject = subject
    redraw()
  }

  /// 本文を裏で測っている（覚えから組めるようになるまで、仮の絵を返す）。
  var isMeasuring: Bool { measures.isMeasuring }

  /// 入力欄の今の本文。
  var text: String { field.string }

  /// 入力欄を空にする（書き込みが通った）。
  func clearField() {
    guard !field.string.isEmpty else { return }
    if let surface {
      surface.replaceText(of: field, with: "")
    } else {
      field.apply([
        TextEdit(range: NSRange(location: 0, length: field.text.length), replacement: "")
      ])
    }
  }

  func redraw() {
    surface?.redrawZone(self)
  }

  private func fieldDidChange(_ field: ZoneTextField) {
    let shape = (field.lineCount, field.string.isEmpty)
    guard shape != fieldShape else { return }
    fieldShape = shape
    redraw()
  }

  // MARK: - 絵の差し込み

  func zone(_ event: ZoneEvent) {
    switch event {
    case .entered(let id):
      hovered = id.base as? PrCommentControl
      redraw()
    case .exited(let id) where hovered == id.base as? PrCommentControl:
      hovered = nil
      redraw()
    case .pressed(let id):
      guard let control = id.base as? PrCommentControl else { return }
      if case .link(let index) = control {
        if let url = links[index] { NSWorkspace.shared.open(url) }
        return
      }
      onPress(self, control)
    default: return
    }
  }

  func picture(width: CGFloat) -> ZonePicture {
    let state = PrCommentPicture.State(
      line: line, hovered: hovered, isWriting: isWriting, isFieldPrimary: isFieldPrimary,
      failure: failure, isLineGone: isLineGone,
      isLineMoving: isLineMoving, language: language)
    let composed: PrCommentPicture.Composed
    switch subject {
    case .draft:
      composed = PrCommentPicture.draft(field: field, state, width: width)
    case .thread(let thread) where isCollapsed:
      composed = PrCommentPicture.collapsed(thread, state, width: width)
    case .thread(let thread):
      let measured = measures.measures(
        thread.comments.map { ($0.id, $0.body) }, width: PrCommentPicture.bodyWidth(width))
      composed = PrCommentPicture.expanded(
        thread, measured: measured, field: field, state, width: width)
    }
    links = composed.links
    return composed.picture
  }
}

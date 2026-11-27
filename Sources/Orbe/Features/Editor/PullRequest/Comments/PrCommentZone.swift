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
  /// 本文のリンク（コメントの id と、そのコメントの本文の層の中の通し番号）。
  case link(comment: String, index: Int)
}

/// diff の行の下に置く、スレッド 1 つか新しいコメントの欄 1 つの絵の差し込み。中身（スレッドの値・書き込みの最中か・失敗の文・
/// 畳んでいるか）は載せる層が置き、ホバーは面からの知らせ（`zone(_:)`）で自分が持つ。どれも変われば描き直させる。絵は
/// `PrCommentPicture` が中身と幅から組む。コメントの本文の層は裏で組み、幅ごとに覚える（→ `PrCommentBodies`）——描き直しは
/// 本文の層を同じ参照のまま絵に置くので、面は本文の層を写し直さない。返信・新しいコメントの本文は入力欄（`field`）に打ち、
/// 載せる層が PR ごとの書きかけと同期する（→ `PrCommentLayer+Drafts`）。
@MainActor
final class PrCommentZone: SurfaceZone {
  enum Subject: Equatable {
    case thread(GitHubPullRequestReview.Thread)
    /// 新しいコメントの欄（書きかけの通し番号）。
    case draft(Int)
  }

  let field: ZoneTextField
  private(set) var subject: Subject
  /// 付いた行の範囲。
  var lines: GitHubLineRange {
    didSet { if lines != oldValue { redraw() } }
  }
  /// 描き直させる面（並びに置いた面。並びを置くたびに載せる層が置き直し、入力欄の主もその層が運ぶ）。
  weak var surface: (any TextSurface)?
  /// 押せる場所が押された。
  var onPress: (PrCommentZone, PrCommentControl) -> Void = { _, _ in }
  /// 入力欄が主になった・外れた。
  var onFieldFocus: (PrCommentZone, Bool) -> Void = { _, _ in }
  /// 人が入力欄の本文を変えた（`setText` で置いた本文は知らせない）。
  var onTextChange: (PrCommentZone) -> Void = { _ in }

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
  /// 欄の下に出す、置き場所の文（無ければ nil）。
  var notice: PrCommentNotice? {
    didSet { if notice != oldValue { redraw() } }
  }
  /// 欄の行を新しい版へ移している（書き込みのボタンを押せない姿にする）。
  var isLineMoving = false {
    didSet { if isLineMoving != oldValue { redraw() } }
  }
  /// 書き込める——欄の行を移している最中でなく、置き場所の文が書き込みを止めるもの（行が現在の diff に無い・スレッドが
  /// 削除された）でない。
  var canSend: Bool { !isLineMoving && notice?.stopsWriting != true }
  /// 入力欄に、空白と改行のほかの字がある。
  var hasText: Bool { PullRequestState.hasText(text) }
  /// スレッドの最初のコメントの時刻（同じ所のスレッドの並び順。欄なら最も古い）。
  var firstCommentTime: Date {
    guard case .thread(let thread) = subject else { return .distantPast }
    return thread.comments.first?.createdAt ?? .distantPast
  }
  var language: Language = .systemDefault {
    didSet { if language != oldValue { redraw() } }
  }
  private(set) var hovered: PrCommentControl?
  private(set) var isFieldPrimary = false
  /// 最後に組んだ絵のリンクの行き先（コメントの id → 本文の層の中の通し番号 → URL）。
  private var links: [String: [Int: URL]] = [:]
  /// 最後に組んだ開いた絵の、コメントごとの縦の範囲（コメントの id → 絵の座標の上端〜下端。畳んだ絵・欄なら空）。
  private(set) var commentSpans: [String: Range<CGFloat>] = [:]
  /// 本文を裏で組み終えて描き直した。
  var onTypeset: (PrCommentZone) -> Void = { _ in }
  private let bodies = PrCommentBodies()
  /// 入力欄の行の数と、空か（字が無いか）と、空白と改行のほかの字が無いか（どれかが変わったときだけ描き直す）。
  private var fieldShape: FieldShape
  /// `setText` が本文を置いている最中。
  private var isSettingText = false

  private struct FieldShape: Equatable {
    let lines: Int
    let empty: Bool
    let blank: Bool
  }

  /// 入力欄の本文の初期値を `text` にする。
  init(subject: Subject, lines: GitHubLineRange, fieldID: String, text: String = "") {
    self.subject = subject
    self.lines = lines
    field = ZoneTextField(id: fieldID, text: text, style: PrCommentStyle.field)
    fieldShape = FieldShape(
      lines: field.lineCount, empty: text.isEmpty, blank: !PullRequestState.hasText(text))
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
    bodies.done = { [weak self] in
      guard let self else { return }
      redraw()
      onTypeset(self)
    }
  }

  /// スレッドの値を置き換える（中身が変われば描き直す）。
  func update(_ subject: Subject) {
    guard subject != self.subject else { return }
    self.subject = subject
    redraw()
  }

  /// 本文を裏で組んでいる（覚えから絵を組めるようになるまで、仮の絵を返す）。
  var isTypesetting: Bool { bodies.isTypesetting }

  /// 入力欄の今の本文。
  var text: String { field.string }

  /// スレッドの絵なら、そのスレッドの id。
  var threadID: String? {
    guard case .thread(let thread) = subject else { return nil }
    return thread.id
  }

  /// 新しいコメントの欄なら、その書きかけの通し番号。
  var draftSerial: Int? {
    guard case .draft(let serial) = subject else { return nil }
    return serial
  }

  /// 入力欄の本文を `text` にする（同じなら何もしない）。載せる層が PR ごとの書きかけを欄へ反映するための口で、
  /// `onTextChange` は呼ばない（反映した本文を書きかけへ書き戻さない）。
  func setText(_ text: String) {
    guard field.string != text else { return }
    isSettingText = true
    defer { isSettingText = false }
    if let surface {
      surface.replaceText(of: field, with: text)
    } else {
      field.apply([
        TextEdit(range: NSRange(location: 0, length: field.text.length), replacement: text)
      ])
    }
  }

  func redraw() {
    surface?.redrawZone(self)
  }

  private func fieldDidChange(_ field: ZoneTextField) {
    if !isSettingText { onTextChange(self) }
    let shape = FieldShape(lines: field.lineCount, empty: field.string.isEmpty, blank: !hasText)
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
      if case .link(let comment, let index) = control {
        if let url = links[comment]?[index] { NSWorkspace.shared.open(url) }
        return
      }
      onPress(self, control)
    default: return
    }
  }

  func picture(width: CGFloat) -> ZonePicture {
    let state = PrCommentPicture.State(
      lines: lines, hovered: hovered, isWriting: isWriting, isFieldPrimary: isFieldPrimary,
      failure: failure, notice: notice, canSend: canSend, hasText: hasText, language: language)
    let composed: PrCommentPicture.Composed
    switch subject {
    case .draft:
      composed = PrCommentPicture.draft(field: field, state, width: width)
    case .thread(let thread) where isCollapsed:
      composed = PrCommentPicture.collapsed(thread, state, width: width)
    case .thread(let thread):
      let bodies = bodies.bodies(
        thread.comments.map { ($0.id, $0.body) }, width: PrCommentPicture.bodyWidth(width))
      composed = PrCommentPicture.expanded(
        thread, bodies: bodies, field: field, state, width: width)
    }
    links = composed.links
    commentSpans = composed.comments
    return composed.picture
  }
}

/// 行を追う欄の下に出す、置き場所の文。
enum PrCommentNotice: Equatable {
  /// 新しいコメントの欄の行が現在の diff に無い（送れない）。
  case lineGone
  /// スレッドが現在の diff の行に付いていない（返信と解決は送れる。行を渡さないので GitHub は受ける）。
  case detached
  /// スレッドが GitHub から削除された（送れない）。
  case deleted

  /// 書き込みを止める。
  var stopsWriting: Bool { self != .detached }

  var key: L10nKey {
    switch self {
    case .lineGone: .editorPrThreadLineGone
    case .detached: .editorPrThreadDetached
    case .deleted: .editorPrThreadDeleted
    }
  }
}

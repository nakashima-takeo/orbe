import AppKit
import SwiftUI

/// コミットメッセージの欄。↵ は改行（VS Code と同じ）、変換中の ↵ は変換の確定だけ（NSTextView のまま）。1 行のときの高さは
/// 見本の 26 で、10 行まで伸び、その先はスクロールする。中身は worktree の状態（`SourceControl.message`）そのもので、同じ
/// worktree を見る別の窓の欄とも同じ値になる。取り消しの履歴は欄ごとに持ち、欄と一緒に消える——窓の履歴に積むと、作り
/// 直された・隠れた欄の打鍵を別の欄の ⌘Z が戻し、見えない worktree のメッセージを書き換える。⌘↵ は pane が取る
/// （→ `EditorPaneView+SourceControl`）。焦点の出入りはパネルへ写し、焦点の要求（ソース管理を開いた・列の先頭で ⌘↑）は
/// ここで当てる。
struct ScmMessageField: NSViewRepresentable {
  let panel: ScmPanel
  let placeholder: String
  @Binding var focused: Bool

  /// 伸びる上限の行数。
  static let maxLines = 10

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let text = ScmMessageTextView()
    context.coordinator.text = text
    text.delegate = context.coordinator
    text.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focusDidChange($0) }
    text.onWindow = { [weak coordinator = context.coordinator] in coordinator?.applyFocusRequest() }
    let scroll = NSScrollView()
    scroll.documentView = text
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.hasHorizontalScroller = false
    text.autoresizingMask = [.width]
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.field = self
    guard let text = scroll.documentView as? ScmMessageTextView else { return }
    text.placeholder = placeholder
    let message = panel.control.message
    if text.string != message, !text.hasMarkedText() {
      text.replaceDiscardingUndo(with: message)
    }
    if panel.focusRequest == .message {
      DispatchQueue.main.async { context.coordinator.applyFocusRequest() }
    }
  }

  /// 中身の行の高さに合わせる（1 行で 26、10 行まで）。
  func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context)
    -> CGSize?
  {
    let width = proposal.width ?? scroll.frame.width
    guard let text = scroll.documentView as? ScmMessageTextView else { return nil }
    return CGSize(width: width, height: text.fittingHeight(width: width, maxLines: Self.maxLines))
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var field: ScmMessageField
    weak var text: ScmMessageTextView?
    private let undo = UndoManager()

    init(_ field: ScmMessageField) {
      self.field = field
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
      guard let text = notification.object as? NSTextView else { return }
      field.panel.control.message = text.string
    }

    func focusDidChange(_ focused: Bool) {
      field.focused = focused
      field.panel.focusDidChange(.message, focused: focused)
    }

    /// 欄へ焦点を入れる要求を当てる（窓に載っていなければ、載ったときにもう一度呼ばれる）。
    func applyFocusRequest() {
      guard field.panel.focusRequest == .message, let text, let window = text.window else { return }
      window.makeFirstResponder(text)
      field.panel.focusRequestDidApply()
    }
  }
}

/// メッセージ欄のテキスト面。空のときプレースホルダを描き、焦点の出入りを知らせる。
final class ScmMessageTextView: NSTextView {
  var placeholder = "" {
    didSet { if placeholder != oldValue, string.isEmpty { needsDisplay = true } }
  }
  var onFocus: ((Bool) -> Void)?
  var onWindow: (() -> Void)?
  /// 手で組んだ文字の系の根（テキスト面はこれを持たないので、自分で持つ）。
  private var storage: NSTextStorage?

  private static let font = Theme.Typography.editorScmMessage
  private static let leading: CGFloat = 8
  private static let trailing: CGFloat = 5

  convenience init() {
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    let layout = NSLayoutManager()
    layout.addTextContainer(container)
    let storage = NSTextStorage()
    storage.addLayoutManager(layout)
    self.init(frame: .zero, textContainer: container)
    self.storage = storage
    font = Self.font
    textColor = Theme.Color.textPrimary
    insertionPointColor = Theme.Color.accentPrimary
    drawsBackground = false
    isRichText = false
    allowsUndo = true
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isVerticallyResizable = true
    isHorizontallyResizable = false
    textContainerInset = NSSize(width: 0, height: Self.verticalInset)
    typingAttributes = [.font: Self.font, .foregroundColor: Theme.Color.textPrimary]
  }

  /// 1 行の高さ。
  private static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) }

  /// 1 行のときに見本の 26 になる上下の余白。
  private static var verticalInset: CGFloat {
    (Theme.Layout.editorScmMessage - lineHeight) / 2
  }

  /// 行の左右の余白（見本 padding 0 5 0 8。テキストコンテナの左右は同じ余白しか持てないので、左はコンテナの原点で動かす）。
  override var textContainerOrigin: NSPoint {
    NSPoint(x: Self.leading, y: super.textContainerOrigin.y)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    textContainer?.containerSize = NSSize(
      width: max(0, newSize.width - Self.leading - Self.trailing),
      height: CGFloat.greatestFiniteMagnitude)
  }

  /// 幅 `width` で中身が収まる高さ（`maxLines` 行まで）。
  func fittingHeight(width: CGFloat, maxLines: Int) -> CGFloat {
    let inset = Self.verticalInset * 2
    guard let container = textContainer, let layout = layoutManager else {
      return Theme.Layout.editorScmMessage
    }
    let available = max(0, width - Self.leading - Self.trailing)
    if container.containerSize.width != available {
      container.containerSize = NSSize(width: available, height: .greatestFiniteMagnitude)
    }
    layout.ensureLayout(for: container)
    let used = max(layout.usedRect(for: container).height, Self.lineHeight)
    return min(used, Self.lineHeight * CGFloat(maxLines)) + inset
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { DispatchQueue.main.async { [weak self] in self?.onWindow?() } }
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { onFocus?(true) }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocus?(false) }
    return resigned
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: Self.font, .foregroundColor: Theme.Color.editorTertiary,
    ]
    let origin = textContainerOrigin
    let line = NSAttributedString(string: placeholder, attributes: attributes)
    line.draw(
      with: NSRect(
        x: origin.x, y: origin.y, width: max(0, bounds.width - origin.x - Self.trailing),
        height: Self.lineHeight),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }

  /// 中身を外から差し替える（コミット後に空にした・別の窓で打った）。差し替えは undo に積まず、欄の取り消しの履歴も捨てる
  /// ——古い履歴は今の文と食い違い、⌘Z が文の外の範囲を戻そうとする。
  func replaceDiscardingUndo(with message: String) {
    breakUndoCoalescing()
    string = message
    undoManager?.removeAllActions()
  }
}

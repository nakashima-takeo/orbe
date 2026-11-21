import AppKit
import SwiftUI

/// コミットメッセージの欄。↵ はコミット（→ `ScmPanel.commitFromMessage`）、改行は ⇧↵・⌥↵・⌃↵、変換中の ↵ は変換の
/// 確定だけ（IME が使った ↵ は改行の命令として届かない）。1 行のときの高さは 26 で、10 行まで伸び、その先は
/// スクロールする。中身は worktree の状態（`SourceControl.message`）そのもので、同じ worktree を見る別の窓の欄とも同じ値に
/// なる。変換中の字は確定するまでメッセージに入れず、パネルの見せ方（`ScmPanel.composition`）に写す。取り消しの履歴は
/// 欄ごとに持ち、欄と一緒に消える——窓の履歴に積むと、作り直された・隠れた欄の打鍵を別の欄の ⌘Z が戻し、見えない
/// worktree のメッセージを書き換える。⌘↵（コミットしてプッシュ）は pane が取る（→ `EditorPaneView+SourceControl`）。
/// 焦点の出入りはパネルへ写し、焦点の要求（ソース管理を開いた・列の先頭で ⌘↑）はここで当てる。
struct ScmMessageField: NSViewRepresentable {
  let panel: ScmPanel
  let placeholder: String
  @Binding var focused: Bool

  /// 伸びる上限の行数。
  static let maxLines = 10

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    // 左右の余白は左 8・右 5（padding 0 5 0 8）。
    let text = MessageTextView(trailing: 5)
    context.coordinator.text = text
    text.delegate = context.coordinator
    text.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focusDidChange($0) }
    text.onWindow = { [weak coordinator = context.coordinator] in coordinator?.applyFocusRequest() }
    text.onCommit = { [weak coordinator = context.coordinator] in
      coordinator?.field.panel.commitFromMessage(andPush: false)
    }
    text.onComposition = { [weak coordinator = context.coordinator] in
      coordinator?.compositionDidChange($0)
    }
    let scroll = MessageScrollView()
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
    guard let text = scroll.documentView as? MessageTextView else { return }
    panel.confirmComposition = { [weak text] in text?.confirmComposition() }
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
    guard let text = scroll.documentView as? MessageTextView else { return nil }
    return CGSize(width: width, height: text.fittingHeight(width: width, maxLines: Self.maxLines))
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var field: ScmMessageField
    weak var text: MessageTextView?
    private let undo = UndoManager()

    init(_ field: ScmMessageField) {
      self.field = field
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
      guard let text = notification.object as? NSTextView else { return }
      field.panel.control.message = text.string
    }

    func compositionDidChange(_ composition: String) {
      if field.panel.composition != composition { field.panel.composition = composition }
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

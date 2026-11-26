import AppKit
import SwiftUI

/// コミットのポップアップのメッセージ欄。↵ はコミット（→ `ScmPanel.commitFromMessage`）、改行は ⇧↵・⌥↵・⌃↵、変換中の ↵ は
/// 変換の確定だけ（IME が使った ↵ は改行の命令として届かない）、変換中でない esc はポップアップを閉じる。1 行のときの高さは
/// 30 で、10 行まで伸び、その先はスクロールする。中身は worktree の状態（`SourceControl.message`）そのもので、同じ worktree を
/// 見る別の窓の欄とも同じ値になる。変換中の字は確定するまでメッセージに入れず、パネルの見せ方（`ScmPanel.composition`）に写し、
/// 欄が消えたらその写しを空にする。取り消しの履歴は欄ごとに持ち、欄と一緒に消える——窓の履歴に積むと、作り直された・隠れた欄の打鍵を
/// 別の欄の ⌘Z が戻し、見えない worktree のメッセージを書き換える。⌘↵（コミットしてプッシュ）はポップアップの器から届く
/// （→ `ScmCommitPopup`）。欄へのフォーカスの要求は、持ち主が欄の窓に載った時点で当てる。
struct ScmMessageField: NSViewRepresentable {
  let owner: ScmCommitPopup
  let placeholder: String

  /// 伸びる上限の行数。
  static let maxLines = 10
  /// 欄の寸法（sans 12.5・行の高さ 20・1 行のときの高さ 30・左右の余白なし）。
  static let metrics = MessageTextView.Metrics(
    font: Theme.Typography.editorCommitMessage, height: Theme.Layout.editorCommitMessage,
    lineHeight: Theme.Layout.editorCommitMessageLine, leading: 0, trailing: 0)

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let text = MessageTextView(metrics: Self.metrics)
    context.coordinator.text = text
    text.delegate = context.coordinator
    text.onWindow = { [weak coordinator = context.coordinator] in
      coordinator?.field.owner.applyFieldFocus()
    }
    text.onCommit = { [weak coordinator = context.coordinator] in
      coordinator?.field.owner.panel.commitFromMessage(andPush: false)
    }
    text.onEscape = { [weak coordinator = context.coordinator] in
      coordinator?.field.owner.close(.escape)
    }
    text.onComposition = { [weak coordinator = context.coordinator] in
      coordinator?.compositionDidChange($0)
    }
    text.setAccessibilityLabel(placeholder)
    owner.field = text
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
    owner.panel.confirmComposition = { [weak text] in text?.confirmComposition() }
    text.placeholder = placeholder
    let message = owner.panel.control.message
    if text.string != message, !text.hasMarkedText() {
      text.replaceDiscardingUndo(with: message)
    }
  }

  /// 欄が消えた（ポップアップが閉じた）。変換中の字の写しを空にする——閉じる直前に確定しているので、ここで残っているのは
  /// 確定の後に届いた写しだけ。
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    let panel = coordinator.field.owner.panel
    if !panel.composition.isEmpty { panel.composition = "" }
  }

  /// 中身の行の高さに合わせる（1 行で 30、10 行まで）。
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
      field.owner.panel.control.message = text.string
    }

    func compositionDidChange(_ composition: String) {
      let panel = field.owner.panel
      if panel.composition != composition { panel.composition = composition }
    }
  }
}

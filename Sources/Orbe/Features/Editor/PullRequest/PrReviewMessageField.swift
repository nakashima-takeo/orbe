import AppKit
import SwiftUI

/// 全体へのコメント欄の箱（余白 5 12——欄の上下 5 と合わせて 10・角丸 9・地 ink .05・枠 ink .15）。送信の最中は押せない姿で、打てない。
struct PrReviewMessageBox: View {
  let popup: PrReviewPopup
  let state: PullRequestState
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Layout.editorPrPopupFieldRadius)
    let writing = state.isWritingReview(.submission)
    PrReviewMessageField(popup: popup, state: state)
      .padding(.horizontal, Theme.Layout.editorPrPopupFieldPadX)
      .padding(.vertical, Theme.Layout.editorPrPopupFieldPadY)
      .background(shape.fill(Color.theme.surfaceInk.opacity(Theme.Opacity.editorPrPopupField)))
      .overlay(
        shape.strokeBorder(
          EditorInk(scheme).hairline(Theme.Opacity.editorPrPopupLine),
          lineWidth: Theme.Stroke.hairline)
      )
      .opacity(writing ? Theme.Opacity.disabled : 1)
      .allowsHitTesting(!writing)
  }
}

/// 全体へのコメント欄。↵ は改行（送信は器が中身へ渡す ⌘↵）、esc（変換中でないとき）は閉じる。1 行のときの高さは 30（行の
/// 高さ 20 と上下 5）で、10 行まで伸び、その先はスクロールする。中身は PR ごとの状態の書きかけそのもの（`PullRequestState.reviewDraft`）。変換中の
/// 字は確定するまで書きかけに入れず、持ち主へ写す（`PrReviewPopup.composition`）。送信の最中は打てない。取り消しの履歴は
/// 欄ごとに持つ（→ `ScmMessageField`）。
struct PrReviewMessageField: NSViewRepresentable {
  let popup: PrReviewPopup
  let state: PullRequestState

  static let metrics = MessageTextView.Metrics(
    font: Theme.Typography.editorPrPopupField, height: Theme.Layout.editorPrPopupFieldHeight,
    lineHeight: Theme.Typography.editorPrPopupFieldLine, leading: 0, trailing: 0)

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let text = MessageTextView(metrics: Self.metrics)
    text.delegate = context.coordinator
    text.onComposition = { [weak coordinator = context.coordinator] composition in
      guard let popup = coordinator?.field.popup, popup.composition != composition else { return }
      popup.composition = composition
    }
    text.onEscape = { [weak coordinator = context.coordinator] in coordinator?.field.popup.escape()
    }
    text.onWindow = { [weak coordinator = context.coordinator] in
      coordinator?.field.popup.applyFocus()
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
    popup.field = text
    text.isEditable = !state.isWritingReview(.submission)
    let body = state.reviewDraft.body
    if text.string != body, !text.hasMarkedText() {
      text.replaceDiscardingUndo(with: body)
    }
    popup.applyFocus()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context)
    -> CGSize?
  {
    let width = proposal.width ?? scroll.frame.width
    guard let text = scroll.documentView as? MessageTextView else { return nil }
    return CGSize(
      width: width, height: text.fittingHeight(width: width, maxLines: ScmMessageField.maxLines))
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var field: PrReviewMessageField
    private let undo = UndoManager()

    init(_ field: PrReviewMessageField) {
      self.field = field
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
      guard let text = notification.object as? NSTextView else { return }
      field.state.reviewDraft.body = text.string
    }
  }
}

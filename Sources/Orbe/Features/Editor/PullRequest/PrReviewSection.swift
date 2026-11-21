import AppKit
import SwiftUI

/// PR のパネルの下端の区画（padding 10 12 12・上縁 hairline .07・段の間 8）: 今の diff に出せない
/// スレッドの件数（あれば）・「レビュー」と保留中のコメントの数・全体へのコメント欄・承認 / コメント / 変更を依頼の 3 択・
/// 「レビューを送信 ⌘↵」・送れない理由か送信の失敗の文・レビューのやりとりの読みの失敗の文（前に読めた内容を出している間も）。
/// ⌘↵ は欄に焦点があるときだけ送信になる（pane が取る → `EditorPaneView+PullRequest`）。区画は PR ごとに作り直す（欄の
/// 同一性を書きかけの持ち主に揃え、変換中に PR が替わっても前の PR の字を次の PR の書きかけに入れない）。
struct PrReviewSection: View {
  let panel: PrPanel
  let state: PullRequestState
  let review: GitHubPullRequestReview
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  var body: some View {
    let ink = EditorInk(scheme)
    VStack(alignment: .leading, spacing: Theme.Layout.editorPrReviewGap) {
      if panel.outdatedThreadCount > 0 { outdated }
      HStack(spacing: Theme.Space.tick) {
        Text(l10n.string(.editorPrReview))
          .font(Font(Theme.Typography.editorPrReviewLabel))
          .foregroundStyle(Color.theme.textMuted)
        Spacer(minLength: 0)
        if let pending = review.pendingReview, pending.commentCount > 0 {
          Circle().fill(Color.theme.editorCaution)
            .frame(width: Theme.Layout.editorPrThreadDot, height: Theme.Layout.editorPrThreadDot)
          Text(l10n.format(.editorPrReviewPending, pending.commentCount))
            .font(Font(Theme.Typography.editorPrCount))
            .foregroundStyle(Color.theme.editorCaution)
        }
      }
      PrReviewMessageBox(
        panel: panel, state: state, placeholder: l10n.string(.editorPrReviewPlaceholder))
      PrReviewEvents(panel: panel, selected: state.reviewDraft.event)
      PrReviewSubmit(panel: panel)
      if let block = panel.submissionBlock {
        PrReviewNote(text: text(block), color: Color.theme.textMuted)
      } else if let failure = state.submissionFailure {
        PrReviewNote(
          text: PrPanelText.writeFailure(failure, l10n.language), color: Color.theme.danger)
      }
      if let failure = state.reviewFailure {
        PrReviewNote(text: PrPanelText.reviewReadFailure(failure, l10n), color: Color.theme.danger)
      }
    }
    .prReviewArea(ink)
  }

  /// 「今の diff に出せないスレッド N 件」（字 11・muted、ホバーで text2）。押すと GitHub の PR を開く。
  private var outdated: some View {
    PrHoverText(
      text: l10n.format(.editorPrOutdatedThreads, panel.outdatedThreadCount),
      action: panel.openOnGitHub)
  }

  private func text(_ block: PrPanel.SubmissionBlock) -> String {
    switch block {
    case .loading: l10n.string(.editorPrReviewAwaitsLatest)
    case .stopped: l10n.string(.editorPrReviewStoppedAligning)
    case .noDiff: l10n.string(.editorPrReviewNoDiff)
    }
  }
}

/// レビューのやりとりを一度も読めていない間の、下端の区画の位置の読みの失敗の文。
struct PrReviewReadFailure: View {
  let failure: GitHubFailure
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  var body: some View {
    PrReviewNote(text: PrPanelText.reviewReadFailure(failure, l10n), color: Color.theme.danger)
      .frame(maxWidth: .infinity, alignment: .leading)
      .prReviewArea(EditorInk(scheme))
  }
}

extension View {
  /// 下端の区画の余白と上縁。
  fileprivate func prReviewArea(_ ink: EditorInk) -> some View {
    padding(.top, Theme.Layout.editorPrReviewPadTop)
      .padding(.horizontal, Theme.Layout.editorPrReviewPadX)
      .padding(.bottom, Theme.Layout.editorPrReviewPadBottom)
      .overlay(alignment: .top) {
        Rectangle().fill(ink.hairline(0.07)).frame(height: Theme.Stroke.hairline)
      }
  }
}

/// 区画の 1 文（字 11・折り返す）。
private struct PrReviewNote: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(Font.theme.editorScmNote)
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// ホバーで字の色が muted から text2 に変わる、押せる 1 行（字 11）。
private struct PrHoverText: View {
  let text: String
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Text(text)
      .font(Font(Theme.Typography.editorPrReviewLabel))
      .foregroundStyle(hovered ? Color.theme.editorText : Color.theme.textMuted)
      .lineLimit(1)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
      .onTapGesture(perform: action)
  }
}

/// 全体へのコメント欄の箱（radius 3・枠 hairline .10・地 sunk .35。焦点で radius 5・枠 accent .55）。送信の最中は
/// 押せない姿で、打てない。
private struct PrReviewMessageBox: View {
  let panel: PrPanel
  let state: PullRequestState
  let placeholder: String
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let ink = EditorInk(scheme)
    let focused = panel.isReviewFieldFocused
    let shape = RoundedRectangle(cornerRadius: focused ? 5 : Theme.Radius.xs)
    PrReviewMessageField(panel: panel, state: state, placeholder: placeholder)
      .background(shape.fill(ink.sunk(0.35)))
      .overlay(
        shape.strokeBorder(
          focused ? Color(nsColor: Theme.Color.editorPrFieldFocus) : ink.hairline(0.10),
          lineWidth: Theme.Stroke.hairline)
      )
      .opacity(state.isWritingReview(.submission) ? Theme.Opacity.disabled : 1)
      .allowsHitTesting(!state.isWritingReview(.submission))
  }
}

/// 承認 / コメント / 変更を依頼の 3 択（外枠 padding 2・角丸 4・間 2・地 sunk .28。各 等分・高さ 22・角丸 3・字 11。選択は
/// chromeText の地に tabActiveText の 600、非選択は muted でホバー text2。選べない種類は押せない姿）。
private struct PrReviewEvents: View {
  let panel: PrPanel
  let selected: GitHubReviewEvent
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  var body: some View {
    let ink = EditorInk(scheme)
    HStack(spacing: Theme.Layout.editorPrReviewSegmentPad) {
      segment(.approve, .editorPrReviewApprove)
      segment(.comment, .editorPrReviewComment)
      segment(.requestChanges, .editorPrReviewRequestChanges)
    }
    .padding(Theme.Layout.editorPrReviewSegmentPad)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(ink.sunk(0.28)))
  }

  private func segment(_ event: GitHubReviewEvent, _ key: L10nKey) -> some View {
    PrReviewSegment(
      label: l10n.string(key), isSelected: selected == event, isEnabled: panel.canChoose(event)
    ) { panel.chooseReviewEvent(event) }
  }
}

private struct PrReviewSegment: View {
  let label: String
  let isSelected: Bool
  let isEnabled: Bool
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Text(label)
      .font(
        Font(
          isSelected
            ? Theme.Typography.editorPrReviewSelected : Theme.Typography.editorPrReviewLabel)
      )
      .foregroundStyle(
        isSelected
          ? Color.theme.tabActiveText
          : hovered && isEnabled ? Color.theme.editorText : Color.theme.textMuted
      )
      .frame(maxWidth: .infinity)
      .frame(height: Theme.Layout.editorPrReviewSegment)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.xs)
          .fill(isSelected ? Color.theme.textPrimary : Color.clear)
      )
      .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
      .onTapGesture { if isEnabled { action() } }
  }
}

/// 「レビューを送信」と「⌘↵」（高さ 26・radius 3・地 accent・字 tabActiveText 12 semibold、⌘↵ は mono 10.5・
/// 不透明度 .7、間 6）。送れない間は押せない姿。
private struct PrReviewSubmit: View {
  let panel: PrPanel
  @Environment(\.localization) private var l10n

  var body: some View {
    let enabled = panel.canSubmitReview
    HStack(spacing: Theme.Space.note) {
      Text(l10n.string(.editorPrReviewSubmit))
        .font(Font(Theme.Typography.editorPrReviewSubmit))
      Text("⌘↵")
        .font(Font(Theme.Typography.editorPrCount))
        .opacity(0.7)
    }
    .foregroundStyle(Color.theme.tabActiveText)
    .frame(maxWidth: .infinity)
    .frame(height: Theme.Layout.editorPrReviewControl)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(Color.theme.accentPrimary))
    .opacity(enabled ? 1 : Theme.Opacity.disabled)
    .contentShape(Rectangle())
    .onTapGesture { if enabled { panel.submitReview() } }
  }
}

/// 全体へのコメント欄。↵ は改行（送信は pane が取る ⌘↵）で、1 行のときの高さは 26、10 行まで伸び、その先はスクロール
/// する。中身は PR ごとの状態の書きかけそのもの（`PullRequestState.reviewDraft`）。変換中の字は確定するまで書きかけに入れず、
/// パネルへ写す（`PrPanel.reviewComposition`）。焦点の出入りもパネルへ写す。送信の最中は打てない。取り消しの履歴は欄ごとに
/// 持つ（→ `ScmMessageField`）。
private struct PrReviewMessageField: NSViewRepresentable {
  let panel: PrPanel
  let state: PullRequestState
  let placeholder: String

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    // 左右の余白は 8（padding 0 8）。
    let text = MessageTextView(trailing: 8)
    context.coordinator.text = text
    text.delegate = context.coordinator
    text.onFocus = { [weak coordinator = context.coordinator] in
      coordinator?.field.panel.isReviewFieldFocused = $0
    }
    text.onComposition = { [weak coordinator = context.coordinator] composition in
      guard let panel = coordinator?.field.panel, panel.reviewComposition != composition else {
        return
      }
      panel.reviewComposition = composition
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
    panel.confirmReviewComposition = { [weak text] in text?.confirmComposition() }
    text.placeholder = placeholder
    text.isEditable = !state.isWritingReview(.submission)
    let body = state.reviewDraft.body
    if text.string != body, !text.hasMarkedText() {
      text.replaceDiscardingUndo(with: body)
    }
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
    weak var text: MessageTextView?
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

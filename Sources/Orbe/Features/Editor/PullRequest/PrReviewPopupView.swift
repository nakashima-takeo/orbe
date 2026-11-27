import AppKit
import SwiftUI

/// レビューのポップアップの中身。上から、区分「全体へのコメント」（見出しと欄）、区分「未送信のコメント N」（数が 1 以上の
/// ときだけ。6 行まで見せ、越える分は区分の中でスクロールする）、今の diff に置けない未解決のスレッドの数（あるときだけ）、
/// 下端（右寄せで種類と「レビューを送信」）、下端の帯（送れない理由か送信の失敗があるときだけ）。種類は、選べる種類が
/// 2 つ以上のときだけ出し、承認を選べば緑、変更を依頼を選べば黄で、地の縁と上側の色づけと、送信のボタンを塗る。送信の最中は、
/// 欄・種類・送信のボタンを押せない姿にする。書きかけは PR ごとの状態が持つので、開くたびに作り直される中身（同一性は器が
/// 持つ）は、開いたときの PR の書きかけから始まる。
struct PrReviewPopupView: View {
  let popup: PrReviewPopup
  let state: PullRequestState
  @Environment(\.localization) private var l10n

  var body: some View {
    let tint = tint
    EditorPopupGround(tint: tint) {
      VStack(alignment: .leading, spacing: 0) {
        section(l10n.string(.editorPrReviewOverall)) {
          PrReviewMessageBox(popup: popup, state: state)
        }
        let pending = state.review?.pendingReview?.commentCount ?? 0
        if pending > 0 {
          section(l10n.format(.editorPrReviewPending, pending)) {
            PrPendingCommentList(popup: popup, comments: state.pendingComments)
          }
        }
        if state.outdatedThreadCount > 0 {
          PrPopupLink(
            text: l10n.format(.editorPrOutdatedThreads, state.outdatedThreadCount),
            action: popup.openOnGitHub
          )
          .padding(
            .horizontal, Theme.Layout.editorPrPopupPad + Theme.Layout.editorPrPopupHeadingPadX
          )
          .padding(.top, Theme.Layout.editorPrPopupSectionGap)
        }
        PrReviewFooter(popup: popup, state: state, tint: tint)
          .padding(.top, Theme.Layout.editorPrPopupPad)
        band
      }
    }
  }

  /// 地の色——選べる種類が 2 つ以上で、選んだ種類が承認なら緑、変更を依頼なら黄。ほかは色なし。
  private var tint: Color? {
    guard state.reviewEvents.count > 1 else { return nil }
    switch state.reviewDraft.event {
    case .approve: return Color.theme.success
    case .requestChanges: return Color.theme.stateWaiting
    case .comment: return nil
    }
  }

  private func section<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Theme.Layout.editorPrPopupSectionGap) {
      Text(title)
        .font(Font(Theme.Typography.editorPrPopupHeading))
        .foregroundStyle(Color.theme.textMuted)
        .lineLimit(1)
        .padding(.horizontal, Theme.Layout.editorPrPopupHeadingPadX)
      content()
    }
    .padding([.top, .horizontal], Theme.Layout.editorPrPopupPad)
  }

  /// 下端の帯——送れない理由（弱い色）か、それが無くて送信の失敗があればその文（赤）。
  @ViewBuilder private var band: some View {
    if let block = state.submissionBlock {
      PrPopupBand(text: text(block), color: Color.theme.textMuted)
    } else if let failure = state.submissionFailure {
      PrPopupBand(
        text: PrPanelText.writeFailure(failure, l10n.language), color: Color.theme.danger)
    }
  }

  private func text(_ block: PullRequestState.SubmissionBlock) -> String {
    switch block {
    case .loading: l10n.string(.editorPrReviewAwaitsLatest)
    case .stopped: l10n.string(.editorPrReviewStoppedAligning)
    case .noDiff: l10n.string(.editorPrReviewNoDiff)
    }
  }
}

/// 下端の帯（余白 9 14 10・地は色の .1・上に色の .3 の線・sans 12 行の高さ 1.55・折り返す）。
private struct PrPopupBand: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .font(Font.theme.editorDockCard)
      .lineSpacing(
        Theme.Typography.editorDockCard.extraLeading(
          lineHeight: Theme.Typography.editorDockCardLineHeight)
      )
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Layout.editorPrPopupBandPadX)
      .padding(.top, Theme.Layout.editorPrPopupBandPadTop)
      .padding(.bottom, Theme.Layout.editorPrPopupBandPadBottom)
      .background(color.opacity(Theme.Opacity.editorPrPopupBand))
      .overlay(alignment: .top) {
        Rectangle().fill(color.opacity(Theme.Opacity.editorPrPopupBandLine))
          .frame(height: Theme.Stroke.hairline)
      }
  }
}

/// ホバーで字の色が muted から text になる、押せる 1 行（sans 12）。
private struct PrPopupLink: View {
  let text: String
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Text(text)
      .font(Font(Theme.Typography.editorPrPopupRow))
      .foregroundStyle(hovered ? Color.theme.editorText : Color.theme.textMuted)
      .lineLimit(1)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
      .onTapGesture(perform: action)
  }
}

/// 未送信のコメントの行のリスト（6 行まで見せ、越える分はスクロールする）。
private struct PrPendingCommentList: View {
  let popup: PrReviewPopup
  let comments: [PullRequestState.PendingComment]

  var body: some View {
    let rows = VStack(spacing: 0) {
      ForEach(comments, id: \.id) { comment in
        PrPendingCommentRow(comment: comment) { popup.press(comment) }
      }
    }
    if comments.count > Theme.Layout.editorPrPopupRows {
      ScrollView(.vertical) { rows }
        .frame(
          height: Theme.Layout.editorPrPopupRow * CGFloat(Theme.Layout.editorPrPopupRows))
    } else {
      rows
    }
  }
}

/// 未送信のコメントの行（高さ 26・左右の余白 8・角丸 6・左右へ 6 はみ出す）: 場所の札 `ファイル名:行`（mono 11.5・accentBright・
/// 地 accent .2）と本文の先頭の 1 行（textSecondary。収まらなければ末尾を省く）。今の diff に置けない行は弱い色。ホバーで地。
private struct PrPendingCommentRow: View {
  let comment: PullRequestState.PendingComment
  let action: () -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var hovered = false

  var body: some View {
    let placeable = comment.isPlaceable
    HStack(spacing: Theme.Layout.editorPrPopupRowGap) {
      Text(place)
        .font(Font(Theme.Typography.editorPrPopupRef))
        .foregroundStyle(placeable ? Color.theme.accentBright : Color.theme.textMuted)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Theme.Layout.editorPrPopupRefPadX)
        .background(
          RoundedRectangle(cornerRadius: Theme.Layout.editorPrPopupRefRadius)
            .fill(
              (placeable ? Color.theme.accentPrimary : Color.theme.surfaceInk)
                .opacity(Theme.Opacity.editorPrPopupRef))
        )
      Text(firstLine)
        .font(Font(Theme.Typography.editorPrPopupRow))
        .foregroundStyle(placeable ? Color.theme.textSecondary : Color.theme.textMuted)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Layout.editorPrPopupRowPadX)
    .frame(height: Theme.Layout.editorPrPopupRow)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorPrPopupRowRadius)
        .fill(hovered ? EditorInk(scheme).fill(Theme.Opacity.editorPrPopupField) : .clear)
    )
    .padding(
      .horizontal, -Theme.Layout.editorPrPopupRowPadX + Theme.Layout.editorPrPopupHeadingPadX
    )
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .onTapGesture(perform: action)
  }

  /// `ファイル名:行`（範囲なら `ファイル名:始まりの行-終わりの行`。側に依らず数字だけ。行を持たなければ `ファイル名`）。
  private var place: String {
    let name = (comment.path as NSString).lastPathComponent
    guard let lines = comment.lines else { return name }
    return "\(name):" + (lines.start.map { "\($0.line)-" } ?? "") + "\(lines.end.line)"
  }

  private var firstLine: String {
    comment.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  }
}

/// 下端（余白 12・上に線・間 10）: 右寄せで、種類（選べる種類が 2 つ以上のときだけ）と「レビューを送信 ⌘↵」。送信のボタンの
/// 地は、承認なら緑、変更を依頼なら黄、ほかはアクセントの色。
private struct PrReviewFooter: View {
  let popup: PrReviewPopup
  let state: PullRequestState
  let tint: Color?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: Theme.Layout.editorPrPopupFooterGap) {
      Spacer(minLength: 0)
      if state.reviewEvents.count > 1 {
        HStack(spacing: Theme.Layout.editorPrPopupEventGap) {
          ForEach(state.reviewEvents, id: \.self) { event in
            PrReviewEventButton(
              event: event, isSelected: state.reviewDraft.event == event,
              isEnabled: state.canChoose(event)
            ) { state.chooseReviewEvent(event) }
          }
        }
      }
      EditorLargeButton(
        title: l10n.string(.editorPrReviewSubmit), key: .text("⌘↵"),
        ground: tint.map { .color($0) } ?? .accent, isEnabled: popup.canSubmit,
        action: { popup.submit() })
    }
    .padding(Theme.Layout.editorPrPopupPad)
    .overlay(alignment: .top) {
      Rectangle().fill(EditorInk(scheme).hairline(Theme.Opacity.editorPrPopupLine))
        .frame(height: Theme.Stroke.hairline)
    }
  }
}

/// 種類の 1 つ（高さ 30・左 9 右 11・角丸 8・間 6・sans 12・textSecondary・枠 ink .15・印 13 muted）。選んだ種類は
/// textPrimary の semibold で、地と枠を塗る（中立は ink .1 と .3、承認は success .16 と .65、変更を依頼は stateWaiting .14
/// と .6。印はその色）。選べない間は押せない姿。
private struct PrReviewEventButton: View {
  let event: GitHubReviewEvent
  let isSelected: Bool
  let isEnabled: Bool
  let action: () -> Void
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Layout.editorPrPopupEventRadius)
    HStack(spacing: Theme.Layout.editorPrPopupEventGap) {
      EditorGlyphView(
        glyph: glyph, size: Theme.Layout.editorPrPopupEventGlyph,
        color: isSelected ? (hue ?? Color.theme.textPrimary) : Color.theme.textMuted)
      Text(l10n.string(label))
        .font(
          Font(
            isSelected
              ? Theme.Typography.editorPrPopupEventSelected : Theme.Typography.editorPrPopupEvent)
        )
        .foregroundStyle(isSelected ? Color.theme.textPrimary : Color.theme.textSecondary)
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.leading, Theme.Layout.editorPrPopupEventPadLeading)
    .padding(.trailing, Theme.Layout.editorPrPopupEventPadTrailing)
    .frame(height: Theme.Layout.editorPrPopupEvent)
    .background(shape.fill(isSelected ? ground : .clear))
    .overlay(shape.strokeBorder(isSelected ? border : line, lineWidth: Theme.Stroke.hairline))
    .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
    .contentShape(Rectangle())
    .onTapGesture { if isEnabled { action() } }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(l10n.string(label))
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var line: Color { EditorInk(scheme).hairline(Theme.Opacity.editorPrPopupLine) }

  /// 選んだときの色（中立なら nil）。
  private var hue: Color? {
    switch event {
    case .approve: Color.theme.success
    case .requestChanges: Color.theme.stateWaiting
    case .comment: nil
    }
  }

  private var ground: Color {
    switch event {
    case .approve: Color.theme.success.opacity(Theme.Opacity.editorPrPopupApproveOn)
    case .requestChanges: Color.theme.stateWaiting.opacity(Theme.Opacity.editorPrPopupChangesOn)
    case .comment: Color.theme.surfaceInk.opacity(Theme.Opacity.editorPrPopupEventOn)
    }
  }

  private var border: Color {
    switch event {
    case .approve: Color.theme.success.opacity(Theme.Opacity.editorPrPopupApproveOnBorder)
    case .requestChanges:
      Color.theme.stateWaiting.opacity(Theme.Opacity.editorPrPopupChangesOnBorder)
    case .comment: Color.theme.surfaceInk.opacity(Theme.Opacity.editorPrPopupEventOnBorder)
    }
  }

  private var glyph: EditorGlyphs.Glyph {
    switch event {
    case .approve: EditorGlyphs.check
    case .requestChanges: EditorGlyphs.requestChanges
    case .comment: EditorGlyphs.comment
    }
  }

  private var label: L10nKey {
    switch event {
    case .approve: .editorPrReviewApprove
    case .requestChanges: .editorPrReviewRequestChanges
    case .comment: .editorPrReviewComment
    }
  }
}

import SwiftUI

/// PR の画面の、上のバーの部品。部品ごとに寄せる側と譲る順を名乗る（→ `editorBarPart`）。
extension EditorBarRoot {
  /// 今の項目の後ろに、左寄せで並ぶ部品——PR の札（中身が読めている間。前に区切り線）・再読込（いつも。札が無ければ前に
  /// 区切り線）・「GitHub で開く」（中身が読めている間）。
  @ViewBuilder var pullRequestMiddle: some View {
    let panel = pullRequestPanel
    if let content = panel.state?.content {
      HStack(spacing: Self.spacing) {
        EditorBarSeparator()
        PrBarChip(content: content)
      }
      .editorBarPart(drops: .chip, grows: .chipWide)
      refreshButton
      EditorBarIconButton(
        glyph: EditorGlyphs.openFile, help: localization.string(.editorPrOpenOnGitHub),
        action: panel.openOnGitHub)
    } else {
      HStack(spacing: Self.spacing) {
        EditorBarSeparator()
        refreshButton
      }
    }
  }

  /// 右端に並ぶ部品——「レビュー」のボタン（open の PR の中身が読めている間）。未送信のコメントがあれば、吹き出しの印と数を
  /// 固定の添えに付ける（譲らない）。レビューのやりとりを読めるまでは押せない姿で、読みの失敗があればツールチップにその文。
  @ViewBuilder var pullRequestTrailing: some View {
    let review = reviewPopup
    if review.isAvailable {
      let count = review.state?.review?.pendingReview?.commentCount ?? 0
      EditorBarActionButton(
        title: localization.string(.editorPrReview), isOpen: review.isOpen,
        isEnabled: review.canOpen, help: reviewHelp(count: count),
        accessibilityName: reviewName(count: count), action: review.toggle,
        badge: { if count > 0 { PrBarPendingCount(count: count) } })
    }
  }

  /// 「レビュー」のボタンのツールチップ——押せない間にレビューのやりとりの読みの失敗があればその文、ほかは VoiceOver の名前。
  private func reviewHelp(count: Int) -> String {
    if !reviewPopup.canOpen, let failure = reviewPopup.state?.reviewFailure {
      return PrPanelText.reviewReadFailure(failure, localization)
    }
    return reviewName(count: count)
  }

  /// 「レビュー」のボタンの VoiceOver の名前（未送信のコメントがあれば、その数を添える）。
  private func reviewName(count: Int) -> String {
    guard count > 0 else { return localization.string(.editorPrReview) }
    return localization.format(.editorPrReviewButtonPending, count)
  }

  private var refreshButton: some View {
    EditorBarIconButton(
      glyph: EditorGlyphs.refresh, help: localization.string(.editorPrRefresh),
      action: pullRequestPanel.refresh)
  }
}

/// PR の札（中ほどの札。地なし。押せない）: `#番号`（muted）・先頭のブランチ名・→・ベースのブランチ名（muted）。渡された幅に
/// 収まるいちばん広い姿を選ぶ——ベースつき、ブランチ名だけ、ブランチ名を省略（先頭 4 字と「…」まで）の順。
struct PrBarChip: View {
  let content: GitHubPullRequestContent
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorBarChip(
      help: l10n.format(
        .editorPrBarChip, content.number, content.headRefName, content.baseRefName),
      content: {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Theme.Layout.editorBarChipGap) {
            number
            Text(content.headRefName).fixedSize()
            EditorGlyphView(
              glyph: EditorGlyphs.arrowRight, size: Theme.Layout.editorPrBarGlyph,
              color: Color.theme.textMuted)
            Text(content.baseRefName).foregroundStyle(Color.theme.textMuted).fixedSize()
          }
          HStack(spacing: Theme.Layout.editorBarChipGap) {
            number
            Text(content.headRefName).fixedSize()
          }
          HStack(spacing: Theme.Layout.editorBarChipGap) {
            number
            EditorReadableName(
              content.headRefName, prefixLength: Theme.Layout.editorBarChipReadablePrefix,
              truncation: .tail
            ) { Text($0) }
          }
        }
      })
  }

  private var number: some View {
    Text("#\(content.number)").foregroundStyle(Color.theme.textMuted).fixedSize()
  }
}

/// 「レビュー」のボタンの未送信の数（間 3・吹き出しの印 12 と数 mono 10.5。stateWaiting）。
struct PrBarPendingCount: View {
  let count: Int

  var body: some View {
    HStack(spacing: Theme.Layout.editorPrBarCountGap) {
      EditorGlyphView(
        glyph: EditorGlyphs.comment, size: Theme.Layout.editorPrBarGlyph,
        color: Color.theme.stateWaiting)
      Text("\(count)").font(Font.theme.editorBarCount).foregroundStyle(Color.theme.stateWaiting)
    }
  }
}

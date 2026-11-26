import SwiftUI

/// コミットのポップアップの中身。ポップアップの地の中に、行（記号「❯」・メッセージ欄・分割ボタン）と、コミットの操作の失敗が
/// 在れば赤い行。▾ のメニューが開いていれば、地のすぐ下（間 6）に右寄せで、一覧の地と行の列を置く。地の何も無い所を押すと、
/// メニューを閉じる。
struct ScmCommitPopupView: View {
  let owner: ScmCommitPopup
  @Environment(\.localization) private var l10n

  var body: some View {
    VStack(alignment: .trailing, spacing: Theme.Layout.editorCommitMenuGap) {
      EditorPopupGround {
        VStack(spacing: 0) {
          row
          if let failure { ScmCommitFailureRow(text: failure) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: owner.pressGround)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(l10n.string(.editorScmCommit))
      if owner.menu.isOpen { menu }
    }
  }

  private var row: some View {
    HStack(alignment: .top, spacing: Theme.Layout.editorCommitRowGap) {
      Text("❯")
        .font(Font.theme.editorCommitPrompt)
        .foregroundStyle(Color.theme.accentBright)
        .frame(height: Theme.Layout.editorCommitMessage)
        .accessibilityHidden(true)
      ScmMessageField(owner: owner, placeholder: l10n.string(.editorScmPlaceholder))
      ScmCommitSplitButton(
        canCommit: owner.panel.commitState.canCommit, commit: commit,
        toggleMenu: owner.toggleMenu)
    }
    .padding(.leading, Theme.Layout.editorCommitRowPadLeading)
    .padding([.top, .bottom, .trailing], Theme.Layout.editorCommitRowPad)
  }

  /// 赤い行に出す失敗の文（コミットの操作の失敗だけ）。
  private var failure: String? {
    let failure = owner.panel.control.failure
    guard ScmFailurePlace(failure, isCommitPopupOpen: true) == .popup, let failure else {
      return nil
    }
    return ScmFailureText.text(failure, l10n.language)
  }

  /// ▾ のメニュー（一覧の地・余白 5・行の列。下の案内は出さない）。
  private var menu: some View {
    GlassPanel(level: .popup, cornerRadius: Theme.Layout.editorCommitMenuRadius) {
      EditorItemListRowListHost(itemList: owner.menu)
        .frame(height: CGFloat(owner.menu.rowCount) * Theme.Layout.editorItemListRow)
        .padding(Theme.Layout.editorItemListPad)
    }
    .frame(width: Theme.Layout.editorCommitMenuWidth)
    .editorDockItem()
  }

  /// 「コミット」（押した時点の写しで押せるときだけ）。
  private func commit() {
    let snapshot = owner.panel.commitSnapshot()
    if snapshot.state.canCommit { snapshot.commit() }
  }
}

/// 分割ボタン（高さ 30・角丸 8）。左「コミット」＋キーの札 ↵、区切り線、右 ▾（説明「その他のコミット操作」）。押せる姿は地
/// accent・字 onAccent・区切り 黒 .22・キーの札の地 黒 .16。左が押せない姿は、地を中立（ink .09）・区切りを ink .12 にし、
/// 左の字を disabled に薄める。▾ はいつも押せる。押してもフォーカスを取らない。
private struct ScmCommitSplitButton: View {
  let canCommit: Bool
  let commit: () -> Void
  let toggleMenu: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(spacing: 0) {
      left
      Rectangle()
        .fill(
          canCommit
            ? Color.black.opacity(Theme.Opacity.editorCommitDivider)
            : Color.theme.surfaceInk.opacity(Theme.Opacity.editorCommitNeutralDivider)
        )
        .frame(width: Theme.Stroke.hairline)
      caret
    }
    .frame(height: Theme.Layout.editorLargeButton)
    .background(
      RoundedRectangle(cornerRadius: Theme.Layout.editorLargeButtonRadius)
        .fill(
          canCommit
            ? Color.theme.accentPrimary
            : Color.theme.surfaceInk.opacity(Theme.Opacity.editorCommitNeutral))
    )
    .fixedSize()
  }

  private var ink: Color { canCommit ? Color.theme.onAccent : Color.theme.textPrimary }

  private var left: some View {
    let title = l10n.string(.editorScmCommit)
    return HStack(spacing: 0) {
      Text(title)
        .font(Font.theme.editorEmptyButton)
        .foregroundStyle(ink)
      Group {
        if canCommit {
          EditorKeyCap(
            content: .glyph(EditorGlyphs.returnKey), foreground: ink,
            ground: Color.black.opacity(Theme.Opacity.editorLargeButtonKeyCap))
        } else {
          EditorKeyCap(content: .glyph(EditorGlyphs.returnKey))
        }
      }
      .padding(.leading, Theme.Layout.editorTextButtonKeyGap)
    }
    .lineLimit(1)
    .opacity(canCommit ? 1 : Theme.Opacity.disabled)
    .padding(.leading, Theme.Layout.editorCommitButtonPadLeading)
    .padding(.trailing, Theme.Layout.editorCommitButtonPadTrailing)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { if canCommit { commit() } }
    .help(title)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityAddTraits(.isButton)
  }

  private var caret: some View {
    let help = l10n.string(.editorScmCommitActions)
    return EditorGlyphView(
      glyph: EditorGlyphs.chevronDown, size: Theme.Layout.editorItemButtonCaret, color: ink
    )
    .padding(.horizontal, Theme.Layout.editorCommitCaretPadX)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture(perform: toggleMenu)
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(help)
    .accessibilityAddTraits(.isButton)
  }
}

/// 赤い行: 上に線 danger .3、地 danger .1（下の角だけポップアップと同じ丸み）、警告の印（上 2）と失敗の文（sans 12・行の高さ
/// 1.55・danger。選択できる）。
private struct ScmCommitFailureRow: View {
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Layout.editorCommitFailureGap) {
      EditorGlyphView(
        glyph: EditorGlyphs.warning, size: Theme.Layout.editorItemButtonCaret,
        color: Color.theme.danger
      )
      .padding(.top, Theme.Layout.editorCommitFailureGlyphTop)
      .accessibilityHidden(true)
      Text(text)
        .font(Font.theme.editorDockCard)
        .lineSpacing(
          Theme.Typography.editorDockCard.extraLeading(
            lineHeight: Theme.Typography.editorDockCardLineHeight)
        )
        .foregroundStyle(Color.theme.danger)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, Theme.Layout.editorCommitFailurePadX)
    .padding(.top, Theme.Layout.editorCommitFailurePadTop)
    .padding(.bottom, Theme.Layout.editorCommitFailurePadBottom)
    .background(
      UnevenRoundedRectangle(
        bottomLeadingRadius: Theme.Layout.editorPopupRadius,
        bottomTrailingRadius: Theme.Layout.editorPopupRadius
      )
      .fill(Color.theme.danger.opacity(Theme.Opacity.editorCommitFailureGround))
    )
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.theme.danger.opacity(Theme.Opacity.editorCommitFailureLine))
        .frame(height: Theme.Stroke.hairline)
    }
    .accessibilityElement(children: .combine)
  }
}

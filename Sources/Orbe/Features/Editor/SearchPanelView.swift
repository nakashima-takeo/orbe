import OrbeEditorCore
import SwiftUI

/// サイドバー: 検索パネル。上から、見出し（題・すべて折りたたむ／すべて展開・「ツリーに戻る」か「止める」。検索中はその
/// 下端に進捗の細い線）→ 入力欄（Aa / ab / .*）→ エラーの文 → 件数の文 → 結果の列。状態は
/// `ProjectSearch` だけを読み、入力欄の焦点は欄の first responder の出入りを `focusedArea` へ写す（結果の列の焦点は列が
/// 自分で写す）。焦点の要求は、入力欄への分は欄が、結果の列への分は列が当てる。
/// 部分ごとに別の view にして、読む値が変わった部分だけを組み直す（結果が届くたびに入力欄まで組み直さない）。
struct SearchPanelView: View {
  let search: ProjectSearch
  let results: RowList<SearchResultsSource>
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorSidebarPanel {
      SearchPanelHeader(search: search)
      ProjectSearchField(search: search)
      if let error = search.error {
        Text(message(for: error))
          .font(Font.theme.editorSearchNote)
          .foregroundStyle(Color.theme.danger)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.bottom, Theme.Space.step)
      }
      SearchSummary(search: search)
      SearchResultsList(search: search, results: results)
    }
    .onDisappear(perform: search.panelDidHide)
  }

  private func message(for error: ProjectSearch.Failure) -> String {
    switch error {
    case .invalidPattern: l10n.string(.editorSearchInvalidRegex)
    case .disk(.couldNotStart): l10n.string(.editorSearchCouldNotStart)
    case .disk(.refused(let line)): line
    }
  }
}

/// 見出し 38: 題・伸びる余白・すべて折りたたむ／すべて展開・字のボタン（2 秒を超えた検索の間は「止める」、それ以外は
/// 「ツリーに戻る」。キーの札 esc つき。押すと Esc と同じ `dismiss`）。検索中は下端に進捗の細い線。字のボタンは 2 つの字の
/// 長い方の幅を確保して右へ寄せ、字が替わってもキーの札と、すべて折りたたむ／すべて展開のボタンを動かさない。幅が足りなければ
/// キーの札を出さず、それでも足りなければ見出しの中身が右端から切れる。
private struct SearchPanelHeader: View {
  let search: ProjectSearch
  @Environment(\.localization) private var l10n

  var body: some View {
    ViewThatFits(in: .horizontal) {
      row(showsKey: true)
      row(showsKey: false)
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .frame(height: Theme.Layout.editorSearchHeader)
    .overlay(alignment: .bottom) {
      if search.showsProgress { EditorProgressLine() }
    }
  }

  private func row(showsKey: Bool) -> some View {
    HStack(spacing: Theme.Layout.editorSearchHeaderGap) {
      Text(l10n.string(.editorSearchTitle))
        .font(Font.theme.editorSearchTitle)
        .foregroundStyle(Color.theme.textPrimary)
        .fixedSize()
      Spacer(minLength: 0)
      if search.isAnyExpanded || search.results.isEmpty {
        EditorIconButton(
          glyph: EditorGlyphs.collapseAll, help: l10n.string(.editorCollapseAll),
          action: search.toggleCollapseAll)
      } else {
        EditorIconButton(
          glyph: EditorGlyphs.expandAll, help: l10n.string(.editorExpandAll),
          action: search.toggleCollapseAll)
      }
      dismissButton(showsKey: showsKey)
    }
    .padding(.leading, Theme.Layout.editorSearchHeaderLeading)
    .padding(.trailing, Theme.Layout.editorSearchHeaderTrailing)
  }

  private func dismissButton(showsKey: Bool) -> some View {
    let key: EditorKeyCap.Content? = showsKey ? .text("esc") : nil
    return ZStack(alignment: .trailing) {
      EditorTextButton(title: l10n.string(.editorSearchBackToTree), key: key) {}.hidden()
      EditorTextButton(title: l10n.string(.editorSearchStop), key: key) {}.hidden()
      EditorTextButton(
        title: l10n.string(search.stopsOnDismiss ? .editorSearchStop : .editorSearchBackToTree),
        key: key
      ) { search.dismiss() }
    }
  }
}

/// 入力欄（入力欄の枠の高さ 28）: 虫眼鏡・入力（mono 12）・右の Aa / ab / .*。フォーカスがある間の枠は入力欄の枠が描く。
/// ↵ と ⇧↵ は検索し直す。esc は見出しのボタンと同じ（キーリピートでは何もしない）。
private struct ProjectSearchField: View {
  let search: ProjectSearch
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorFieldFrame(
      height: Theme.Layout.editorSearchField, isFocused: search.focusedArea == .field
    ) {
      EditorTextField(
        text: search.query.pattern, placeholder: l10n.string(.editorSearchPlaceholder),
        font: Theme.Typography.editorSearchField, placeholderColor: Theme.Color.editorTertiary,
        wantsFocus: search.focusRequest == .field, requestDidApply: search.focusRequestDidApply,
        onTextChange: search.setPattern,
        onFocusChange: { search.focusDidChange(.field, focused: $0) },
        onReturn: { _ in search.search() },
        onEscape: { search.dismiss(isRepeat: $0) })
    } accessory: {
      HStack(spacing: Theme.Layout.editorFieldGap) {
        SearchOption(
          label: "Aa", underline: false, isOn: search.query.matchCase,
          help: l10n.string(.editorSearchMatchCase)
        ) { search.toggle(.matchCase) }
        SearchOption(
          label: "ab", underline: true, isOn: search.query.wholeWord,
          help: l10n.string(.editorSearchWholeWord)
        ) { search.toggle(.wholeWord) }
        SearchOption(
          label: ".*", underline: false, isOn: search.query.isRegex,
          help: l10n.string(.editorSearchRegex)
        ) { search.toggle(.regex) }
      }
    }
    .padding(.horizontal, Theme.Space.step)
    .padding(.bottom, Theme.Layout.editorSearchFieldBottom)
  }
}

/// 入力欄の右のオプション 20 角（radius 3、10pt）。有効は地 tint(accent, .25)・枠 tint(accent, .55)・文字 accentBright、
/// ホバーは地 fill(.08)。
private struct SearchOption: View {
  let label: String
  let underline: Bool
  let isOn: Bool
  let help: String
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme

  private static let onFillAlpha = 0.25
  private static let onBorderAlpha = 0.55
  private static let hoverFillAlpha = 0.08

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.xs)
    Text(label)
      .font(Font.theme.editorSearchOption)
      .underline(underline)
      .foregroundStyle(isOn ? Color.theme.accentBright : Color.theme.textMuted)
      .frame(width: Theme.Layout.editorSearchOption, height: Theme.Layout.editorSearchOption)
      .background(
        shape.fill(
          isOn
            ? Color.theme.accentPrimary.opacity(Self.onFillAlpha)
            : hovering ? EditorInk(scheme).fill(Self.hoverFillAlpha) : .clear)
      )
      .overlay {
        if isOn {
          shape.strokeBorder(
            Color.theme.accentPrimary.opacity(Self.onBorderAlpha), lineWidth: Theme.Stroke.hairline)
        }
      }
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      .onTapGesture(perform: action)
      .help(help)
  }
}

/// 入力欄と結果の列の間の件数の文（11pt tertiary、上 4・左右 12・下 8）。打ち切り・0 件もここに出す。
private struct SearchSummary: View {
  let search: ProjectSearch
  @Environment(\.localization) private var l10n

  var body: some View {
    let lines = self.lines
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: Theme.Space.hair) {
        ForEach(lines, id: \.self) { line in
          Text(line)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .font(Font.theme.editorSearchNote)
      .foregroundStyle(Color.theme.editorTertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, Theme.Layout.editorSearchSummaryTop)
      .padding(.horizontal, 12)
      .padding(.bottom, Theme.Space.step)
    }
  }

  private var lines: [String] {
    let results = search.results
    guard search.error == nil, !search.query.isEmpty else { return [] }
    guard !results.isEmpty else {
      return search.phase == .done ? [l10n.string(.editorSearchNoResults)] : []
    }
    let files = l10n.plural(
      results.files.count, one: .editorSearchFilesOne, other: .editorSearchFilesOther)
    let total = l10n.plural(
      results.total, one: .editorSearchResultsOne, other: .editorSearchResultsOther)
    let summary = l10n.format(.editorSearchSummary, files, total)
    return results.isLimited ? [summary, l10n.string(.editorSearchLimited)] : [summary]
  }
}

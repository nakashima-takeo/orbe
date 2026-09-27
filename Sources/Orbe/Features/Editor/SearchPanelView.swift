import OrbeEditorCore
import SwiftUI

/// サイドバー: 検索パネル（見本 SearchPanel を u4 で詰めた比率に揃えたもの）。上から、ヘッダー（題・更新／停止・クリア・
/// すべて折りたたむ／すべて展開。検索中はその下端に進捗の細い線）→ 入力欄（Aa / ab / .*）→ エラーの文 → 結果の列 → 件数の文
/// （パネルの下に固定）。状態は `ProjectSearch` だけを読み、入力欄の焦点は SwiftUI の焦点を `focusedArea` へ写す（結果の列の
/// 焦点は列が自分で写す）。部分ごとに別の view にして、読む値が変わった部分だけを組み直す（結果が届くたびに入力欄まで
/// 組み直さない）。
struct SearchPanelView: View {
  let search: ProjectSearch
  @FocusState private var fieldFocused: Bool
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorSidebarPanel {
      SearchPanelHeader(search: search)
      ProjectSearchField(search: search, focus: $fieldFocused)
      if let error = search.error {
        Text(message(for: error))
          .font(Font.theme.editorSearchNote)
          .foregroundStyle(Color.theme.danger)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.bottom, Theme.Space.step)
      }
      SearchResultsList(search: search)
      SearchSummary(search: search)
    }
    .onChange(of: fieldFocused) { _, focused in search.focusDidChange(.field, focused: focused) }
    .onChange(of: search.focusRequest) { _, _ in applyFocusRequest() }
    .onAppear(perform: applyFocusRequest)
    .onDisappear(perform: search.panelDidHide)
  }

  /// 入力欄への要求を当てる（結果の列への要求は列が当てる）。
  private func applyFocusRequest() {
    guard search.focusRequest == .field else { return }
    fieldFocused = true
    search.focusRequestDidApply()
  }

  private func message(for error: ProjectSearch.Failure) -> String {
    switch error {
    case .invalidPattern: l10n.string(.editorSearchInvalidRegex)
    case .disk(.couldNotStart): l10n.string(.editorSearchCouldNotStart)
    case .disk(.refused(let line)): line
    }
  }
}

/// ヘッダー: 題と右端のツール（更新（2 秒を超えた検索では停止）・クリア・すべて折りたたむ／すべて展開）。検索中は下端に
/// 進捗の細い線。
private struct SearchPanelHeader: View {
  let search: ProjectSearch
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorPanelHeader(title: l10n.string(.editorSearchTitle)) {
      if search.phase == .slow {
        EditorIconButton(
          glyph: EditorGlyphs.stop, help: l10n.string(.editorSearchStop), action: search.stop)
      } else {
        EditorIconButton(
          glyph: EditorGlyphs.refresh, help: l10n.string(.editorSearchRefresh),
          action: { search.search() })
      }
      EditorIconButton(
        glyph: EditorGlyphs.clear, help: l10n.string(.editorSearchClear), action: search.clear)
      if search.isAnyExpanded || search.results.isEmpty {
        EditorIconButton(
          glyph: EditorGlyphs.collapseAll, help: l10n.string(.editorCollapseAll),
          action: search.toggleCollapseAll)
      } else {
        EditorIconButton(
          glyph: EditorGlyphs.expandAll, help: l10n.string(.editorSearchExpandAll),
          action: search.toggleCollapseAll)
      }
    }
    .overlay(alignment: .bottom) {
      if search.showsProgress { SearchProgressLine() }
    }
  }
}

/// 入力欄 28: 入力（mono 12）と右端の Aa / ab / .*。焦点があると枠が accent になり角が 5 に（見本 inputBox）。
private struct ProjectSearchField: View {
  let search: ProjectSearch
  var focus: FocusState<Bool>.Binding
  @Environment(\.colorScheme) private var scheme
  @Environment(\.localization) private var l10n

  private static let sunkAlpha = 0.35
  private static let borderAlpha = 0.10
  private static let focusBorderAlpha = 0.55

  var body: some View {
    let ink = EditorInk(scheme)
    let focused = focus.wrappedValue
    HStack(spacing: 6) {
      TextField(
        "", text: Binding(get: { search.query.pattern }, set: search.setPattern),
        prompt: Text(l10n.string(.editorSearchPlaceholder)).foregroundStyle(
          Color.theme.editorTertiary)
      )
      .textFieldStyle(.plain)
      .font(Font.theme.editorSearchField)
      .foregroundStyle(Color.theme.textPrimary)
      .tint(Color.theme.accentPrimary)
      .lineLimit(1)
      .focused(focus)
      .onSubmit { search.search() }
      .onKeyPress(.escape) {
        search.stop()
        return .handled
      }
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
    .padding(.horizontal, Theme.Space.step)
    .frame(height: Theme.Layout.editorSearchField)
    .background(
      RoundedRectangle(cornerRadius: focused ? 5 : Theme.Radius.xs).fill(ink.sunk(Self.sunkAlpha))
    )
    .overlay(
      RoundedRectangle(cornerRadius: focused ? 5 : Theme.Radius.xs)
        .strokeBorder(
          focused
            ? Color.theme.accentPrimary.opacity(Self.focusBorderAlpha)
            : ink.hairline(Self.borderAlpha),
          lineWidth: Theme.Stroke.hairline)
    )
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
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

/// 検索中の進捗の細い線（見本に無い。VS Code のビューの上端の線）——accent の短い帯が左から右へ流れ続ける。帯の動きは
/// Core Animation に任せる——SwiftUI の時刻で毎フレーム描くと、検索の間ずっと main が毎フレームパネルを組み直し、結果の
/// 差し込みや打鍵を待たせる。
private struct SearchProgressLine: NSViewRepresentable {
  func makeNSView(context: Context) -> SearchProgressLineView { SearchProgressLineView() }
  func updateNSView(_ view: SearchProgressLineView, context: Context) {}

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: SearchProgressLineView, context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: Theme.Layout.editorSearchProgress)
  }
}

private final class SearchProgressLineView: NSView {
  private static let period: CFTimeInterval = 1.2
  private static let segment: CGFloat = 0.3
  private let bar = CALayer()
  private var animatedWidth: CGFloat?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(bar)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      bar.backgroundColor = Theme.Color.accentPrimary.cgColor
    }
  }

  override func layout() {
    super.layout()
    guard bounds.width != animatedWidth else { return }
    animatedWidth = bounds.width
    let width = bounds.width * Self.segment
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bar.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
    CATransaction.commit()
    let flow = CABasicAnimation(keyPath: "position.x")
    flow.fromValue = -width / 2
    flow.toValue = bounds.width + width / 2
    flow.duration = Self.period
    flow.repeatCount = .infinity
    bar.add(flow, forKey: "flow")
  }
}

/// パネルの下に固定する件数の文（11pt tertiary、padding 10 12）。打ち切り・0 件もここに出す。
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
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
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

import Markdown
import SwiftUI

/// 変更内容シート（見本 2b）。トーストの「変更内容」と設定の「変更内容」が同じここへ着地する。
/// ノートは appcast description の Markdown を、その構造（見出し・箇条書き・段落）のまま描く。
struct UpdateChangesCard: View {
  let state: UpdateState
  /// カード全体の高さ上限（窓に収める。UpdateChangesOverlay が窓高から算出して渡す）。
  let maxHeight: CGFloat
  @Environment(\.localization) private var l10n
  /// ノート内容の実測高（ハグ用）と、ノート以外＝見出し・検証済み行・ボタン・脚注の実測高。
  @State private var notesContentHeight: CGFloat = 0
  @State private var chromeHeight: CGFloat = 0

  /// カード内容の上下パディング（chrome 高に含まれないので上限から別途差し引く）。
  private static let verticalPadding = Theme.Space.bar + 2

  /// ノート部の実効高。内容にハグしつつ「上限 − ノート以外」で頭打ち（超過分は内部スクロールへ）。
  private var notesHeight: CGFloat {
    let available = max(0, maxHeight - chromeHeight - Self.verticalPadding * 2)
    return min(notesContentHeight, available)
  }

  var body: some View {
    GlassPanel(level: .settings, cornerRadius: 14) {
      VStack(alignment: .leading, spacing: 0) {
        header.background(chromeProbe)
        if let notes = state.ready?.notes { notesScroll(notes) }
        footer.background(chromeProbe)
      }
      .padding(.vertical, Self.verticalPadding)
      .padding(.horizontal, Theme.Space.span)
      .frame(width: 450, alignment: .leading)
    }
    // 実測が届くまでの 1 フレームも窓を超えないよう、器そのものにも上限を効かせる。
    .frame(maxHeight: maxHeight)
    .onPreferenceChange(UpdateChromeHeightKey.self) { chromeHeight = $0 }
  }

  /// 見出し・検証済み行・ボタン・脚注の実測高を合算して chrome 高に集約する probe。
  private var chromeProbe: some View {
    GeometryReader { geo in
      Color.clear.preference(key: UpdateChromeHeightKey.self, value: geo.size.height)
    }
  }

  /// ノート部。長いノートはここだけがスクロールし、見出し・検証済み行・ボタンは常に見える。
  /// 上の余白はスクロール内容側に持たせ、実測高＝ノート部の占有高に一致させる。
  private func notesScroll(_ markdown: String) -> some View {
    ScrollView {
      UpdateNotesView(markdown: markdown)
        .padding(.top, Theme.Space.bar - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: UpdateNotesHeightKey.self, value: geo.size.height)
          })
    }
    // 定高を与える（fixedSize だと内容高へ伸び切り、カードが窓外へはみ出してボタンに届かなくなる）。
    .frame(height: notesHeight)
    .scrollIndicators(.automatic)
    .onPreferenceChange(UpdateNotesHeightKey.self) { notesContentHeight = $0 }
  }

  /// 検証済み行＋ボタン行＋脚注。スクロール領域の外に置き、ノートの長さによらず常に見える。
  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      verifiedLine
        .padding(.top, Theme.Space.bar)
      HStack(spacing: Theme.Space.step) {
        Button {
          state.onRestartNow()
        } label: {
          Text(l10n.string(.updateRestartAndUpdate))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(DSPrimaryButtonStyle())
        Button(l10n.string(.updateCloseButton)) { state.onCloseChanges() }
          .buttonStyle(DSSecondaryButtonStyle())
      }
      .padding(.top, Theme.Space.beat)
      Text(l10n.string(.updateSheetFootnote))
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.step)
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: Theme.Space.hair + 1) {
        Text(l10n.format(.updateSheetTitle, "v\(state.ready?.version ?? "")"))
          .font(Font.theme.title.weight(.bold))
          .foregroundStyle(Color.theme.textPrimary)
        Text(metaLine)
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
      }
      Spacer(minLength: 0)
      Button {
        state.onCloseChanges()
      } label: {
        Text("✕")
          .font(Font.theme.label)
          .foregroundStyle(Color.theme.textMuted)
      }
      .buttonStyle(.plain)
    }
  }

  /// 「2026年7月13日 · 13 MB」（日付・サイズは不明分を落として · で結ぶ）。
  private var metaLine: String {
    var parts: [String] = []
    if let date = state.ready?.date {
      let formatter = DateFormatter()
      formatter.locale = l10n.language.dateLocale
      formatter.dateStyle = .long
      formatter.timeStyle = .none
      parts.append(formatter.string(from: date))
    }
    if let size = state.ready?.size, size > 0 {
      parts.append(UpdateByteText.string(size))
    }
    return parts.joined(separator: " · ")
  }

  /// 「✓ Developer ID 署名と公証を検証済み」——更新経路への信頼シグナル（見本 2b）。
  private var verifiedLine: some View {
    HStack(spacing: Theme.Space.note) {
      Text("✓").foregroundStyle(Color.theme.stateDone)
      Text(l10n.string(.updateVerifiedLine)).foregroundStyle(Color.theme.textMuted)
    }
    .font(Font.theme.meta)
    .padding(.top, Theme.Space.beat)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
    }
  }
}

/// ノート以外（見出し・検証済み行・ボタン・脚注）の合算高。ノート部の上限から差し引く。
struct UpdateChromeHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

/// ノート内容の実測高（内容ハグ用）。
struct UpdateNotesHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// appcast description（Markdown）を変更内容シートの描画要素へ写した値型。
/// Markdown が持つ区別——見出し＝セクション、箇条書き＝項目、それ以外＝段落——だけを保ち、
/// 意味は入力の内容（見出しの語）からだけ決める（出現順からは何も作らない）。
/// 描画と分けてあるのは変換結果をテストで見るため。
struct UpdateNotes: Equatable {
  /// 要素の由来。Markdown の箇条書き項目か、それ以外の段落か——表示側はこれ以上を足さない。
  enum ElementKind: Equatable {
    case item
    case paragraph
  }

  /// セクションの分類。見出しの語だけで決まり、並び順・個数には依存しない。
  /// 語彙の出所は release スキルが固定するリリースノートの見出し 3 種（`### 新機能` / `### 改善` / `### 修正`）。
  /// 規約外の見出し・見出し無しは `.neutral` へ落ちる。意匠（色・マーカー）はここではなく View が持つ。
  enum Category: Equatable {
    case feature
    case improvement
    case fix
    case neutral

    /// 見出し語 → 分類の対応表。表示側がこの語彙を知る唯一の点。
    init(title: String?) {
      switch title?.trimmingCharacters(in: .whitespaces) {
      case "新機能": self = .feature
      case "改善": self = .improvement
      case "修正": self = .fix
      default: self = .neutral
      }
    }
  }

  /// セクション配下の 1 要素。由来と、インライン Markdown を解釈した本文を持つ。
  struct Element: Equatable {
    let kind: ElementKind
    let text: AttributedString
  }

  /// 見出し 1 つとその配下の要素列。見出しより前の要素は title なしのセクションに入る。
  struct Section: Equatable {
    let title: String?
    let category: Category
    let elements: [Element]
  }

  let sections: [Section]

  init(markdown: String) {
    var built: [(title: String?, elements: [Element])] = []
    func append(_ kind: ElementKind, _ inline: String) {
      // format() はブロックの区切り（前後の改行・リストのインデント）ごと返すので端を落とす。
      // 落とした結果が空なら要素にしない（中身のない項目は項目ではなく、マーカーだけの行になる）。
      let body = inline.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return }
      if built.isEmpty { built.append((title: nil, elements: [])) }
      built[built.count - 1].elements.append(Element(kind: kind, text: Self.attributed(body)))
    }
    for block in Document(parsing: markdown).children {
      switch block {
      case let heading as Heading:
        built.append((title: heading.plainText, elements: []))
      case let list as UnorderedList:
        for item in list.listItems {
          append(
            .item, item.children.compactMap { ($0 as? Paragraph)?.format() }.joined(separator: " "))
        }
      case let paragraph as Paragraph:
        append(.paragraph, paragraph.format())
      default:
        break
      }
    }
    sections = built.map {
      Section(title: $0.title, category: Category(title: $0.title), elements: $0.elements)
    }
  }

  /// インライン（`code`・強調等）は AttributedString の Markdown 解釈に委ねる（コードは等幅で描かれる）。
  private static func attributed(_ inline: String) -> AttributedString {
    (try? AttributedString(
      markdown: inline, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(inline)
  }
}

/// リリースノートの描画。分類が持つ色とマーカーを見出しと項目マーカーが共有し、本文は常に textSecondary。
/// 分類は見出しの語から決まるので、「修正」しか無いノートでも修正は修正の意匠で描かれる。
struct UpdateNotesView: View {
  private let notes: UpdateNotes

  init(markdown: String) {
    notes = UpdateNotes(markdown: markdown)
  }

  /// 分類の色（見出しとマーカーが共有する）。新機能=working(青) / 改善=waiting(黄) / 修正=muted、
  /// 規約外は中立の textPrimary——色数を増やさず「知らない見出し」を素の見出しとして描く。
  private static func accent(_ category: UpdateNotes.Category) -> Color {
    switch category {
    case .feature: Color.theme.stateWorking
    case .improvement: Color.theme.stateWaiting
    case .fix: Color.theme.textMuted
    case .neutral: Color.theme.textPrimary
    }
  }

  /// 分類のマーカー。増えるもの（新機能・改善）は `＋`、直したもの（修正）は `✓`、中立は `•`。
  private static func marker(_ category: UpdateNotes.Category) -> String {
    switch category {
    case .feature, .improvement: "＋"
    case .fix: "✓"
    case .neutral: "•"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.beat) {
      ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
        let accent = Self.accent(section.category)
        VStack(alignment: .leading, spacing: Theme.Space.note) {
          if let title = section.title {
            Text(title)
              .font(Font.theme.meta.weight(.bold))
              .foregroundStyle(accent)
              .tracking(Theme.Typography.trackingLabel)
          }
          ForEach(Array(section.elements.enumerated()), id: \.offset) { _, element in
            switch element.kind {
            case .item:
              HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step) {
                Text(Self.marker(section.category))
                  .font(Font.theme.body)
                  .foregroundStyle(accent)
                noteText(element.text, color: Color.theme.textSecondary)
              }
            case .paragraph:
              noteText(element.text, color: Color.theme.textSecondary)
            }
          }
        }
      }
    }
  }

  /// 本文の行送りは design-system §2.3 の `line.body` 1.6。12.5pt 本文の素の行高 15 との差。
  private static let bodyLineSpacing: CGFloat = 12.5 * Theme.Typography.lineBody - 15

  /// tint も渡すのは、素の URL が自動でリンク化されるため——リンクは foregroundStyle ではなく
  /// tint で色が付き、既定のままだと出典行だけがパレット外の青で浮く。
  /// 上下の余白は行送りの半分——lineSpacing は行と行の間しか広げないので、これを足して初めて
  /// 1 行の要素も複数行の要素も同じ行ボックスを持ち、要素間の余白（spacing）が素の値のまま効く。
  private func noteText(_ text: AttributedString, color: Color) -> some View {
    Text(text)
      .font(Font.theme.body)
      .lineSpacing(Self.bodyLineSpacing)
      .foregroundStyle(color)
      .tint(color)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, Self.bodyLineSpacing / 2)
  }
}

/// バイト数の表示（"13 MB" / "8.3 MB"）。DL 進捗と変更内容シートが共有する mono 表記の語彙。
enum UpdateByteText {
  static func string(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_000_000
    return mb >= 10 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f MB", mb)
  }
}

/// フルウィンドウ overlay。dim scrim ＋ 中央のシート。scrim タップ / Esc / 閉じる＝同じ着地
/// （閉じても終了時に自動適用——どのボタンを押しても損しない）。↵ は「再起動して更新」。
struct UpdateChangesOverlay: View {
  @Bindable var model: UpdateState
  @FocusState private var focused: Bool

  var body: some View {
    // 窓高からカードの高さ上限を作る（上下に span の余白を残す）。項目の多いノートはカード内で
    // スクロールへ回り、シートが窓外へはみ出さない。
    GeometryReader { geo in
      ZStack {
        Scrim(strength: .strong)
          .contentShape(Rectangle())
          .onTapGesture { model.onCloseChanges() }
        UpdateChangesCard(
          state: model, maxHeight: max(0, geo.size.height - Theme.Space.span * 2))
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .ignoresSafeArea()
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(.escape) {
      model.onCloseChanges()
      return .handled
    }
    .onKeyPress(.return) {
      model.onRestartNow()
      return .handled
    }
    .onChange(of: model.changesFocusToken, initial: true) { focused = true }
  }
}

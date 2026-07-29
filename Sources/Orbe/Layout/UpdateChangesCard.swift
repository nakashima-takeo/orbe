import Markdown
import SwiftUI

/// 変更内容シート（見本 2b）。トーストの「変更内容」と設定の「変更内容」が同じここへ着地する。
/// ノートは appcast description の Markdown を、その構造（見出し・箇条書き・段落）のまま描く。
struct UpdateChangesCard: View {
  let state: UpdateState
  @Environment(\.localization) private var l10n

  var body: some View {
    GlassPanel(level: .settings, cornerRadius: 14) {
      VStack(alignment: .leading, spacing: 0) {
        header
        if let notes = state.ready?.notes {
          UpdateNotesView(markdown: notes)
            .padding(.top, Theme.Space.bar - 2)
        }
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
      .padding(.vertical, Theme.Space.bar + 2)
      .padding(.horizontal, Theme.Space.span)
      .frame(width: 450, alignment: .leading)
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

/// appcast description（Markdown）を変更内容シートの描画要素へ写した値型。
/// Markdown が持つ区別——見出し＝セクション、箇条書き＝項目、それ以外＝段落——だけを保ち、
/// 出現順から意味（色・マーカー）を作らない。描画と分けてあるのは変換結果をテストで見るため。
struct UpdateNotes: Equatable {
  /// 要素の由来。Markdown の箇条書き項目か、それ以外の段落か——表示側はこれ以上を足さない。
  enum ElementKind: Equatable {
    case item
    case paragraph
  }

  /// セクション配下の 1 要素。由来と、インライン Markdown を解釈した本文を持つ。
  struct Element: Equatable {
    let kind: ElementKind
    let text: AttributedString
  }

  /// 見出し 1 つとその配下の要素列。見出しより前の要素は title なしのセクションに入る。
  struct Section: Equatable {
    let title: String?
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
    sections = built.map { Section(title: $0.title, elements: $0.elements) }
  }

  /// インライン（`code`・強調等）は AttributedString の Markdown 解釈に委ねる（コードは等幅で描かれる）。
  private static func attributed(_ inline: String) -> AttributedString {
    (try? AttributedString(
      markdown: inline, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(inline)
  }
}

/// リリースノートの描画。色の階層は 見出し=textPrimary / 本文=textSecondary / マーカー=textMuted。
/// マーカーは常に `•`——`＋ / −` は diff の語彙（design-system §3）で、ノートには流用しない。
struct UpdateNotesView: View {
  private let notes: UpdateNotes

  init(markdown: String) {
    notes = UpdateNotes(markdown: markdown)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.beat) {
      ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
        VStack(alignment: .leading, spacing: Theme.Space.note) {
          if let title = section.title {
            Text(title)
              .font(Font.theme.meta.weight(.bold))
              .foregroundStyle(Color.theme.textPrimary)
              .tracking(Theme.Typography.trackingStatus * 2)
          }
          ForEach(Array(section.elements.enumerated()), id: \.offset) { _, element in
            switch element.kind {
            case .item:
              HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step) {
                Text("•")
                  .font(Font.theme.body)
                  .foregroundStyle(Color.theme.textMuted)
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

  /// tint も渡すのは、素の URL が自動でリンク化されるため——リンクは foregroundStyle ではなく
  /// tint で色が付き、既定のままだと出典行だけがパレット外の青で浮く。
  private func noteText(_ text: AttributedString, color: Color) -> some View {
    Text(text)
      .font(Font.theme.body)
      .foregroundStyle(color)
      .tint(color)
      .fixedSize(horizontal: false, vertical: true)
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
    ZStack {
      Scrim(strength: .strong)
        .contentShape(Rectangle())
        .onTapGesture { model.onCloseChanges() }
      UpdateChangesCard(state: model)
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

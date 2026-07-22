import Markdown
import SwiftUI

/// 変更内容シート（見本 2b）。トーストの「変更内容」と設定の「変更内容」が同じここへ着地する。
/// ノートは appcast description の Markdown（見出し＝分類・箇条書き＝項目）を 3 分類の意匠で描く。
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
          .font(Font.theme.meta)
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
      formatter.locale = Locale(identifier: l10n.language == .ja ? "ja_JP" : "en_US")
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

/// appcast description（Markdown）の 3 分類描画。見出し（任意レベル）＝分類、箇条書き＝項目。
/// 分類色は見本 2b の順（新機能=working / 改善=waiting / 修正=muted）を出現順で循環する。
struct UpdateNotesView: View {
  private struct NoteSection: Identifiable {
    let id: Int
    let title: String?
    let items: [AttributedString]
  }
  private let sections: [NoteSection]

  init(markdown: String) {
    // 見出しで区切り、リスト項目/段落を項目として拾う。インライン（`code` 等）は AttributedString の
    // Markdown 解釈に委ねる（コードは等幅で描かれる）。
    var built: [(title: String?, items: [AttributedString])] = []
    func appendItem(_ inline: String) {
      let attributed =
        (try? AttributedString(
          markdown: inline, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(inline)
      if built.isEmpty { built.append((title: nil, items: [])) }
      built[built.count - 1].items.append(attributed)
    }
    for block in Document(parsing: markdown).children {
      switch block {
      case let heading as Heading:
        built.append((title: heading.plainText, items: []))
      case let list as UnorderedList:
        for item in list.listItems {
          appendItem(
            item.children.compactMap { ($0 as? Paragraph)?.format() }.joined(separator: " "))
        }
      case let paragraph as Paragraph:
        appendItem(paragraph.format())
      default:
        break
      }
    }
    sections = built.enumerated().map { NoteSection(id: $0, title: $1.title, items: $1.items) }
  }

  /// 分類見出しの色（出現順）: working → waiting → muted（見本 2b の 新機能/改善/修正）。
  private func sectionColor(_ index: Int) -> Color {
    let cycle: [Color] = [.theme.stateWorking, .theme.stateWaiting, .theme.textMuted]
    return cycle[index % cycle.count]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.beat) {
      ForEach(sections) { section in
        VStack(alignment: .leading, spacing: Theme.Space.note) {
          if let title = section.title {
            Text(title)
              .font(Font.theme.meta.weight(.bold))
              .foregroundStyle(sectionColor(section.id))
              .tracking(Theme.Typography.trackingStatus * 2)
          }
          ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.note + 1) {
              Text(section.id < 2 ? "＋" : "✓")
                .font(Font.theme.bodySmall)
                .foregroundStyle(Color.theme.stateDone)
              Text(item)
                .font(Font.theme.body)
                .foregroundStyle(Color.theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
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

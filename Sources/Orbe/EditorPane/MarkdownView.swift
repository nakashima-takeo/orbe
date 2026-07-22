import Markdown
import SwiftUI

/// MarkdownView の描画スタイル（フォント・色・面・余白）。既定値＝レンダラの素の見た目。
/// EditorPane の md プレビューは `.editorPane` スタイルを environment で注入して差し替える
/// （スタイル差し替えが唯一の見た目分岐点）。
struct MarkdownStyle {
  var titleFont: Font = Font.theme.title  // h1
  var headingFont: Font = Font.theme.label  // h2 以降
  var headingUnderline = false  // h2 の下線（EditorPane プレビュー）
  var bodyFont: Font = Font.theme.body
  var bodyLineSpacing: CGFloat = 0
  var bulletColor: Color = Color.theme.textMuted
  var inlineCodeFont: Font = Font.theme.code
  var inlineCodeBackground: Color = Color.theme.bgSunken
  var codeBlockFont: Font = Font.theme.code
  var codeBlockColor: Color = Color.theme.textPrimary
  var codeBlockBackground: Color = Color.theme.bgSunken
  var codeBlockBordered = false
  var codeBlockRadius: CGFloat = Theme.Radius.sm
  var blockSpacing: CGFloat = Theme.Space.beat
  var contentPadding = EdgeInsets(
    top: Theme.Space.bar, leading: Theme.Space.bar,
    bottom: Theme.Space.bar, trailing: Theme.Space.bar)
}

extension EnvironmentValues {
  @Entry var markdownStyle = MarkdownStyle()
}

/// swift-markdown の `Document` AST を SwiftUI へ再帰描画する read-only の markdown レンダラ。
/// 見出し/段落/箇条書き（ネスト）/番号付き/引用/コードブロック/表/水平線/GFM タスクリストに対応。
/// GFM タスクリスト項目は `item.checkbox` の状態を静的なチェックマークで表示する（トグル不可）。
struct MarkdownView: View {
  let markdown: String
  @Environment(\.markdownStyle) private var style

  var body: some View {
    let document = Document(parsing: markdown)
    ScrollView {
      VStack(alignment: .leading, spacing: style.blockSpacing) {
        ForEach(Array(document.blockChildren.enumerated()), id: \.offset) { _, child in
          MarkdownBlockView(markup: child)
        }
      }
      .padding(style.contentPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// 1 ブロック（`Markup` ノード）を型で振り分けて描く。自身を子に含む再帰 View
/// （リスト項目・引用の中身はネストしうるため）。
struct MarkdownBlockView: View {
  let markup: Markup
  @Environment(\.markdownStyle) private var style

  var body: some View {
    switch markup {
    case let heading as Heading:
      // 見出し階層はサイズでなく weight と色で刻む:
      // h1=title/primary・h2=heading/primary・h3 以降=heading/secondary。
      MarkdownInline.text(of: heading, style: style)
        .font(heading.level <= 1 ? style.titleFont : style.headingFont)
        .foregroundStyle(heading.level >= 3 ? Color.theme.textSecondary : Color.theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(
          maxWidth: style.headingUnderline && heading.level == 2 ? .infinity : nil,
          alignment: .leading
        )
        .padding(.bottom, style.headingUnderline && heading.level == 2 ? 4 : 0)
        .overlay(alignment: .bottom) {
          if style.headingUnderline && heading.level == 2 {
            Rectangle().fill(Color.theme.surfaceInk.opacity(0.08)).frame(height: 1)
          }
        }
    case let paragraph as Paragraph:
      MarkdownInline.text(of: paragraph, style: style)
        .font(style.bodyFont)
        .lineSpacing(style.bodyLineSpacing)
        .foregroundStyle(Color.theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    case let list as UnorderedList:
      listView(items: Array(list.listItems), ordered: false, start: 1)
    case let list as OrderedList:
      listView(items: Array(list.listItems), ordered: true, start: Int(list.startIndex))
    case let quote as BlockQuote:
      quoteView(quote)
    case let code as CodeBlock:
      codeView(code.code)
    case let table as Markdown.Table:
      MarkdownTableView(table: table)
    case is ThematicBreak:
      Rectangle()
        .fill(Color.theme.surface1)
        .frame(height: Theme.Stroke.hairline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.step)
    default:
      // 未対応ブロック（HTML ブロック等）は中身を落とさず素描画する。
      SwiftUI.Text(markup.format())
        .font(Font.theme.body)
        .foregroundStyle(Color.theme.textMuted)
    }
  }

  // MARK: - リスト（箇条書き / 番号付き / GFM タスクリスト）

  @ViewBuilder private func listView(items: [ListItem], ordered: Bool, start: Int) -> some View {
    VStack(alignment: .leading, spacing: Theme.Space.step) {
      ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
        if item.checkbox != nil {
          taskRow(item)
        } else {
          bulletRow(item, marker: ordered ? "\(start + idx)." : "•")
        }
      }
    }
  }

  /// 非タスクのリスト項目。マーカー＋先頭段落＋ネスト子ブロックを字下げで描く。
  private func bulletRow(_ item: ListItem, marker: String) -> some View {
    HStack(alignment: .top, spacing: Theme.Space.step) {
      SwiftUI.Text(marker)
        .font(style.bodyFont)
        .foregroundStyle(style.bulletColor)
      itemContent(item)
    }
  }

  /// GFM タスクリスト項目を静的なチェックマークで描く（`checkmark.square.fill` / `square`・トグル不可）。
  /// ラベル行（チェックボックス＋先頭段落）に続けて、ネストした子ブロック（サブリスト・追加段落・
  /// コードブロック等）を非タスク項目（`itemContent`）と同じく字下げ再帰する。
  @ViewBuilder private func taskRow(_ item: ListItem) -> some View {
    let checked = item.checkbox == .checked
    VStack(alignment: .leading, spacing: Theme.Space.step) {
      HStack(alignment: .top, spacing: Theme.Space.step) {
        Image(systemName: checked ? "checkmark.square.fill" : "square")
          .foregroundStyle(Color.theme.textMuted)
        SwiftUI.Text(MarkdownInline.taskLabel(of: item, style: style))
          .font(style.bodyFont)
          .foregroundStyle(Color.theme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      ForEach(Array(nestedChildren(of: item).enumerated()), id: \.offset) { _, child in
        MarkdownBlockView(markup: child)
          .padding(.leading, Theme.Space.bar)
      }
    }
  }

  /// タスク項目のラベルに使った先頭段落を除いた、字下げ再帰する子ブロック群。
  /// `taskLabel` が拾う先頭 Paragraph と同じ 1 件を取り除く。
  private func nestedChildren(of item: ListItem) -> [Markup] {
    var children = Array(item.blockChildren)
    if let labelIdx = children.firstIndex(where: { $0 is Paragraph }) {
      children.remove(at: labelIdx)
    }
    return children
  }

  /// リスト項目の中身。先頭段落を本文として、残り（ネストしたリスト等）を字下げ再帰する。
  @ViewBuilder private func itemContent(_ item: ListItem) -> some View {
    let children = Array(item.blockChildren)
    VStack(alignment: .leading, spacing: Theme.Space.step) {
      ForEach(Array(children.enumerated()), id: \.offset) { idx, child in
        if idx == 0, let para = child as? Paragraph {
          MarkdownInline.text(of: para, style: style)
            .font(style.bodyFont)
            .lineSpacing(style.bodyLineSpacing)
            .foregroundStyle(Color.theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          MarkdownBlockView(markup: child)
            .padding(.leading, Theme.Space.bar)
        }
      }
    }
  }

  private func quoteView(_ quote: BlockQuote) -> some View {
    HStack(alignment: .top, spacing: Theme.Space.step) {
      Rectangle()
        .fill(Color.theme.surface1)
        .frame(width: Theme.Stroke.marker)
      VStack(alignment: .leading, spacing: Theme.Space.step) {
        ForEach(Array(quote.blockChildren.enumerated()), id: \.offset) { _, child in
          MarkdownBlockView(markup: child)
        }
      }
    }
  }

  private func codeView(_ text: String) -> some View {
    SwiftUI.Text(text.hasSuffix("\n") ? String(text.dropLast()) : text)
      .font(style.codeBlockFont)
      .foregroundStyle(style.codeBlockColor)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(
        style.codeBlockBordered
          ? EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12)  // 見本のコードブロック余白
          : EdgeInsets(
            top: Theme.Space.step, leading: Theme.Space.step,
            bottom: Theme.Space.step, trailing: Theme.Space.step)
      )
      .background(
        RoundedRectangle(cornerRadius: style.codeBlockRadius).fill(style.codeBlockBackground)
      )
      .overlay {
        if style.codeBlockBordered {
          RoundedRectangle(cornerRadius: style.codeBlockRadius)
            .strokeBorder(Color.theme.surfaceInk.opacity(0.06), lineWidth: 1)
        }
      }
  }
}

/// GFM 表。ヘッダ行＋区切り＋本文行を Grid で描く。セルはインライン描画。
struct MarkdownTableView: View {
  let table: Markdown.Table
  @Environment(\.markdownStyle) private var style

  var body: some View {
    let headCells = Array(table.head.cells)
    let bodyRows = Array(table.body.rows)
    Grid(alignment: .leading, horizontalSpacing: Theme.Space.bar, verticalSpacing: Theme.Space.step)
    {
      GridRow {
        ForEach(Array(headCells.enumerated()), id: \.offset) { _, cell in
          MarkdownInline.text(of: cell, style: style)
            .font(Font.theme.labelStrong)
            .foregroundStyle(Color.theme.textPrimary)
        }
      }
      Rectangle()
        .fill(Color.theme.surface1)
        .frame(height: Theme.Stroke.hairline)
        .gridCellColumns(max(headCells.count, 1))
      ForEach(Array(bodyRows.enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
            MarkdownInline.text(of: cell, style: style)
              .font(style.bodyFont)
              .foregroundStyle(Color.theme.textSecondary)
          }
        }
      }
    }
    .padding(Theme.Space.step)
    .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Color.theme.bgSunken))
  }
}

/// インライン markup（強調・コードスパン・リンク・取り消し線）を `AttributedString` へ畳む。
enum MarkdownInline {
  /// インラインコンテナ（段落・見出し・表セル）の中身を `Text` で描く。
  static func text(of container: Markup, style: MarkdownStyle = MarkdownStyle()) -> SwiftUI.Text {
    var result = AttributedString()
    for child in container.children { result += render(child, style: style) }
    return SwiftUI.Text(result)
  }

  /// GFM タスクリスト項目のラベル（先頭段落のインライン）を返す。
  static func taskLabel(
    of item: ListItem, style: MarkdownStyle = MarkdownStyle()
  ) -> AttributedString {
    var attributed = AttributedString()
    if let para = item.blockChildren.first(where: { $0 is Paragraph }) {
      for child in para.children { attributed += render(child, style: style) }
    }
    return attributed
  }

  // MARK: - 再帰

  private static func render(_ markup: Markup, style: MarkdownStyle) -> AttributedString {
    switch markup {
    case let text as Markdown.Text:
      return AttributedString(text.string)
    case let code as InlineCode:
      var s = AttributedString(code.code)
      s.font = style.inlineCodeFont
      s.backgroundColor = style.inlineCodeBackground
      return s
    case let emphasis as Emphasis:
      return apply(children(of: emphasis, style: style), intent: .emphasized)
    case let strong as Strong:
      return apply(children(of: strong, style: style), intent: .stronglyEmphasized)
    case let strike as Strikethrough:
      var s = children(of: strike, style: style)
      for run in s.runs { s[run.range].strikethroughStyle = .single }
      return s
    case let link as Markdown.Link:
      var s = children(of: link, style: style)
      for run in s.runs {
        s[run.range].foregroundColor = Color.theme.accentPrimary
        s[run.range].underlineStyle = .single
      }
      return s
    case is SoftBreak:
      return AttributedString(" ")
    case is LineBreak:
      return AttributedString("\n")
    default:
      // Image / InlineHTML 等は素の plainText で落とさず描く。
      return AttributedString((markup as? InlineMarkup)?.plainText ?? markup.format())
    }
  }

  private static func children(of markup: Markup, style: MarkdownStyle) -> AttributedString {
    var result = AttributedString()
    for child in markup.children { result += render(child, style: style) }
    return result
  }

  /// 子の attributed に強調 intent を重ねる（ネストした強調を潰さず union する）。
  private static func apply(_ attributed: AttributedString, intent: InlinePresentationIntent)
    -> AttributedString
  {
    var s = attributed
    for run in s.runs {
      let existing = s[run.range].inlinePresentationIntent ?? []
      s[run.range].inlinePresentationIntent = existing.union(intent)
    }
    return s
  }
}

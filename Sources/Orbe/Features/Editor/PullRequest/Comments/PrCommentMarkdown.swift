import AppKit
import Markdown
import OrbeEditorCore

/// コメントの本文の段 1 つ——段落・見出し・箇条書きの項目の段・引用の中の段は字の段、コードブロックはコードの段。どの
/// スレッドへも渡せる値。
struct PrCommentBlock: Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case text
    case code
  }

  var kind: Kind
  /// 本文の左端からの字下げ（pt）。箇条書きの段と引用の段ごとに深くなる。
  var indent: CGFloat
  /// 引用の線の x（本文の左端から。外側の引用から順に）。
  var quoteBars: [CGFloat]
  /// 箇条書きの印（項目の最初の段だけ。字下げの左の空きに描く）。
  var marker: String?
  var text: ZoneStyledText
  /// 見え方の番号 → リンクの行き先。
  var links: [Int: URL]
  /// 取り消し線を引く見え方の番号。
  var strikes: Set<Int>
}

/// コメントの本文（GitHub の Markdown）を段の列に変換する（純関数。どのスレッドからも呼べる）。描くのは段落・インライン
/// コード・太字・斜体・取り消し線・リンク・コードブロック・箇条書き・引用・見出しまでで、ほかの記法（表・画像・HTML・
/// suggestion など）は書かれた字のまま段落かインラインの字にする——字は欠けない。
enum PrCommentMarkdown {
  static func blocks(_ source: String) -> [PrCommentBlock] {
    var converter = Converter(source: source)
    converter.visit(children: Document(parsing: source), Context())
    return converter.blocks
  }

  /// 段の置き方（字下げ・引用・箇条書きの印・地の字の色）。
  fileprivate struct Context {
    var indent: CGFloat = 0
    var quoteBars: [CGFloat] = []
    var marker: String?
    var quoted = false
  }

  /// 字の見え方の組（太字・斜体・取り消し線・リンク・見出し）。
  fileprivate struct Inline {
    var strong = false
    var emphasis = false
    var strike = false
    var link: URL?
  }

  fileprivate struct Converter {
    let source: String
    /// 行ごとの先頭の UTF-8 のオフセット（記法の範囲を元の字に戻す）。
    let lineStarts: [Int]
    var blocks: [PrCommentBlock] = []

    init(source: String) {
      self.source = source
      var starts = [0]
      for (offset, byte) in source.utf8.enumerated() where byte == 0x0A {
        starts.append(offset + 1)
      }
      lineStarts = starts
    }

    mutating func visit(children markup: Markup, _ context: Context) {
      var context = context
      for child in markup.children {
        visit(block: child, context)
        // 箇条書きの印は項目の最初の段だけに付ける。
        context.marker = nil
      }
    }

    mutating func visit(block markup: Markup, _ context: Context) {
      switch markup {
      case let paragraph as Paragraph:
        append(inline: paragraph, context, heading: false)
      case let heading as Heading:
        append(inline: heading, context, heading: true)
      case let code as CodeBlock where code.language != "suggestion":
        var text = ZoneStyledText()
        let body = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
        text.append(body, Self.style(Theme.Typography.editorPrThreadCode, Theme.Color.editorText))
        blocks.append(
          PrCommentBlock(
            kind: .code, indent: context.indent, quoteBars: context.quoteBars,
            marker: context.marker, text: text, links: [:], strikes: []))
      case let quote as BlockQuote:
        var inner = context
        inner.quoteBars.append(context.indent)
        inner.indent += Theme.Layout.editorPrBodyQuoteBar + Theme.Layout.editorPrBodyQuoteGap
        inner.quoted = true
        visit(children: quote, inner)
      case let list as UnorderedList:
        visit(list: list, context) { _ in "•" }
      case let list as OrderedList:
        let start = Int(list.startIndex)
        visit(list: list, context) { "\(start + $0)." }
      default:
        appendRaw(markup, context)
      }
    }

    private mutating func visit(
      list: ListItemContainer, _ context: Context, marker: (Int) -> String
    ) {
      for (index, item) in list.listItems.enumerated() {
        var inner = context
        inner.indent += Theme.Layout.editorPrBodyListIndent
        inner.marker = marker(index)
        var first = true
        for child in item.children {
          if first, let checkbox = item.checkbox, let paragraph = child as? Paragraph {
            append(
              inline: paragraph, inner, heading: false,
              prefix: checkbox == .checked ? "[x] " : "[ ] ")
          } else {
            visit(block: child, inner)
          }
          inner.marker = nil
          first = false
        }
        if first {
          blocks.append(
            PrCommentBlock(
              kind: .text, indent: inner.indent, quoteBars: inner.quoteBars, marker: inner.marker,
              text: ZoneStyledText(), links: [:], strikes: []))
        }
      }
    }

    /// 段落・見出しの中身を字の段にする。
    private mutating func append(
      inline container: Markup, _ context: Context, heading: Bool, prefix: String = ""
    ) {
      var block = PrCommentBlock(
        kind: .text, indent: context.indent, quoteBars: context.quoteBars, marker: context.marker,
        text: ZoneStyledText(), links: [:], strikes: [])
      let inline = Inline(strong: heading)
      if !prefix.isEmpty { add(prefix, inline, context, into: &block) }
      for child in container.children { visit(inline: child, inline, context, into: &block) }
      blocks.append(block)
    }

    private func visit(
      inline markup: Markup, _ inline: Inline, _ context: Context,
      into block: inout PrCommentBlock
    ) {
      var inner = inline
      switch markup {
      case let text as Markdown.Text: add(text.string, inline, context, into: &block)
      case let code as InlineCode:
        guard !code.code.isEmpty else { return }
        let style = ZoneTextStyle(
          font: Theme.Typography.editorPrThreadCode, color: Theme.Color.accentBright,
          padding: Theme.Layout.editorPrInlineCodePad)
        mark(inline, at: block.text.styles.count, in: &block)
        block.text.append(code.code, style)
      case is SoftBreak: add(" ", inline, context, into: &block)
      case is Markdown.LineBreak: add("\n", inline, context, into: &block)
      case let emphasis as Emphasis:
        inner.emphasis = true
        for child in emphasis.children { visit(inline: child, inner, context, into: &block) }
      case let strong as Strong:
        inner.strong = true
        for child in strong.children { visit(inline: child, inner, context, into: &block) }
      case let strike as Strikethrough:
        inner.strike = true
        for child in strike.children { visit(inline: child, inner, context, into: &block) }
      case let link as Markdown.Link:
        inner.link = link.destination.flatMap(URL.init(string:))
        for child in link.children { visit(inline: child, inner, context, into: &block) }
      default:
        add(raw(markup), inline, context, into: &block)
      }
    }

    /// 字の連なりを、見え方の組で段の後ろに足す。
    private func add(
      _ string: String, _ inline: Inline, _ context: Context, into block: inout PrCommentBlock
    ) {
      guard !string.isEmpty else { return }
      let font =
        inline.strong
        ? Theme.Typography.editorPrThreadBodyStrong : Theme.Typography.editorPrThreadBody
      let color =
        inline.link != nil
        ? Theme.Color.accentBright : context.quoted ? Theme.Color.textMuted : Theme.Color.editorText
      mark(inline, at: block.text.styles.count, in: &block)
      block.text.append(string, Self.style(inline.emphasis ? Self.italic(font) : font, color))
    }

    /// 見え方 `index` の取り消し線とリンクを段に記す。
    private func mark(_ inline: Inline, at index: Int, in block: inout PrCommentBlock) {
      if inline.strike { block.strikes.insert(index) }
      if let link = inline.link { block.links[index] = link }
    }

    /// 描かない記法の段を、書かれた字のまま段落にする。
    private mutating func appendRaw(_ markup: Markup, _ context: Context) {
      var block = PrCommentBlock(
        kind: .text, indent: context.indent, quoteBars: context.quoteBars, marker: context.marker,
        text: ZoneStyledText(), links: [:], strikes: [])
      let text = raw(markup)
      add(text.hasSuffix("\n") ? String(text.dropLast()) : text, Inline(), context, into: &block)
      blocks.append(block)
    }

    /// 記法の範囲の、書かれた字。範囲が分からなければ記法を字に起こし直したもの。
    private func raw(_ markup: Markup) -> String {
      guard let range = markup.range, let lower = offset(range.lowerBound),
        let upper = offset(range.upperBound), lower <= upper
      else { return markup.format() }
      let utf8 = source.utf8
      let from = utf8.index(utf8.startIndex, offsetBy: lower)
      let to = utf8.index(utf8.startIndex, offsetBy: upper)
      return String(source[from..<to])
    }

    /// 位置（1 始まりの行と、行の中の 1 始まりの UTF-8 の桁）の、元の字の UTF-8 のオフセット。
    private func offset(_ location: SourceLocation) -> Int? {
      guard location.line >= 1, location.line <= lineStarts.count else { return nil }
      return min(lineStarts[location.line - 1] + location.column - 1, source.utf8.count)
    }

    static func style(_ font: NSFont, _ color: NSColor) -> ZoneTextStyle {
      ZoneTextStyle(font: font, color: color)
    }

    /// システムの字体の斜体（本物の斜体の字体。和文は直立のまま）。
    static func italic(_ font: NSFont) -> NSFont {
      CTFontCreateCopyWithSymbolicTraits(font as CTFont, 0, nil, .traitItalic, .traitItalic)
        .map { $0 as NSFont } ?? font
    }
  }
}

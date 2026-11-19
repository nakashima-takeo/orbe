import AppKit
import OrbeEditorCore
import cmark_gfm
import cmark_gfm_extensions

/// cmark の木を、走査の入りと出の列として平らにたどり、段の列にする（→ `PrCommentMarkdown`）。
extension PrCommentMarkdown {
  typealias Node = UnsafeMutablePointer<cmark_node>

  /// 段の置き方（字下げ・引用の線・地の字の色・入れ子の段の数）。
  struct Context {
    var indent: CGFloat = 0
    var quoteBars: [PrCommentBlock.QuoteBar] = []
    var quoted = false
    var depth = 0
  }

  /// 開いている入れ物（走査の入りで積み、出で降ろす）。
  struct Frame {
    let node: Node
    let context: Context
    /// 箇条書きの次の項目の番号と、項目の字下げ。
    var next = 0
    var listIndent: CGFloat = 0
    /// 番号付きの箇条書きの、項目ごとの番号の幅（項目の順）。
    var numberWidths: [CGFloat] = []
    /// 項目が入った時点の段の数（段を 1 つも出さなかった項目は、印だけの段にする）。
    var blocksAtEntry = 0
  }

  struct Converter {
    /// 元の字の UTF-8 と、行ごとの先頭の UTF-8 のオフセット（記法の範囲を元の字に戻す）。
    let utf8: [UInt8]
    let lineStarts: [Int]
    var blocks: [PrCommentBlock] = []
    private var frames: [Frame] = []
    /// 次に出す段に付ける箇条書きの印。
    private var markers: [PrCommentBlock.Marker] = []
    /// 書いている字の段と、字の見え方（太字・斜体・取り消し線の入れ子の数と、リンクの行き先の列）。
    private var block: PrCommentBlock?
    private var strong = 0
    private var emphasis = 0
    private var strike = 0
    private var links: [URL?] = []
    /// 次の引用の番号。
    private var quotes = 0

    init(source: String) {
      utf8 = Array(source.utf8)
      var starts = [0]
      for (offset, byte) in utf8.enumerated() where byte == 0x0A {
        starts.append(offset + 1)
      }
      lineStarts = starts
    }

    private var context: Context { frames.last?.context ?? Context() }

    mutating func walk(_ document: Node) {
      guard let iterator = cmark_iter_new(document) else { return }
      defer { cmark_iter_free(iterator) }
      /// 書かれた字のまま出した入れ物（中身はたどらない）。
      var skipping: Node?
      while true {
        let event = cmark_iter_next(iterator)
        if event == CMARK_EVENT_DONE { break }
        guard let node = cmark_iter_get_node(iterator) else { continue }
        if let skipped = skipping {
          if event == CMARK_EVENT_EXIT, node == skipped { skipping = nil }
          continue
        }
        if event == CMARK_EVENT_ENTER {
          if enter(node) { skipping = node }
        } else {
          exit(node)
        }
      }
    }

    /// 入れ物か葉に入る。中身をたどらずに書かれた字のまま出したら true。
    private mutating func enter(_ node: Node) -> Bool {
      let type = cmark_node_get_type(node)
      switch type {
      case CMARK_NODE_DOCUMENT: return false
      case CMARK_NODE_PARAGRAPH, CMARK_NODE_HEADING:
        begin()
        if type == CMARK_NODE_HEADING { strong += 1 }
        if let item = frames.last, PrCommentMarkdown.typeName(item.node) == "tasklist",
          cmark_node_first_child(item.node) == node
        {
          add(cmark_gfm_extensions_get_tasklist_item_checked(item.node) ? "[x] " : "[ ] ")
        }
        return false
      case CMARK_NODE_CODE_BLOCK:
        let code = PrCommentMarkdown.literal(node)
        let body = code.hasSuffix("\n") ? String(code.dropLast()) : code
        if PrCommentMarkdown.string(cmark_node_get_fence_info(node)) == "suggestion" {
          appendText("```suggestion\n" + code + "```")
        } else {
          var text = ZoneStyledText()
          text.append(
            body,
            PrCommentMarkdown.style(Theme.Typography.editorPrThreadCode, Theme.Color.editorText))
          emit(
            PrCommentBlock(
              kind: .code, indent: context.indent, quoteBars: context.quoteBars, markers: [],
              text: text, links: [:], strikes: []))
        }
        return false
      case CMARK_NODE_FOOTNOTE_DEFINITION:
        // 定義の始まりの桁は中身の始まりなので、ラベルの字を足して書かれた字に戻す。
        appendText("[^" + PrCommentMarkdown.literal(node) + "]: " + raw(node))
        return cmark_node_first_child(node) != nil
      case CMARK_NODE_HTML_BLOCK:
        let html = PrCommentMarkdown.literal(node)
        appendText(html.hasSuffix("\n") ? String(html.dropLast()) : html)
        return false
      case CMARK_NODE_BLOCK_QUOTE:
        var inner = context
        if inner.depth < PrCommentMarkdown.maxDepth {
          inner.quoteBars.append(PrCommentBlock.QuoteBar(x: inner.indent, quote: quotes))
          inner.indent += Theme.Layout.editorPrBodyQuoteBar + Theme.Layout.editorPrBodyQuoteGap
          inner.depth += 1
        }
        quotes += 1
        inner.quoted = true
        frames.append(Frame(node: node, context: inner))
        return false
      case CMARK_NODE_LIST:
        frames.append(list(node))
        return false
      case CMARK_NODE_ITEM:
        item(node)
        return false
      default:
        return enterInline(node)
      }
    }

    /// インラインの葉か入れ物に入る。描かない記法の段なら書かれた字のまま出し、中身をたどらないなら true。
    private mutating func enterInline(_ node: Node) -> Bool {
      switch cmark_node_get_type(node) {
      case CMARK_NODE_TEXT:
        addText(PrCommentMarkdown.literal(node))
        return false
      case CMARK_NODE_CODE:
        let code = PrCommentMarkdown.literal(node)
        guard !code.isEmpty, block != nil else { return false }
        mark(at: block!.text.styles.count)
        block!.text.append(
          code,
          ZoneTextStyle(
            font: Theme.Typography.editorPrThreadCode, color: Theme.Color.accentBright,
            padding: Theme.Layout.editorPrInlineCodePad))
        return false
      case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK:
        add("\n")
        return false
      case CMARK_NODE_EMPH:
        emphasis += 1
        return false
      case CMARK_NODE_STRONG:
        strong += 1
        return false
      case CMARK_NODE_LINK:
        links.append(PrCommentMarkdown.allowed(PrCommentMarkdown.string(cmark_node_get_url(node))))
        return false
      case CMARK_NODE_IMAGE:
        add("![")
        return false
      case CMARK_NODE_FOOTNOTE_REFERENCE:
        // cmark は参照の字を通し番号に書き換えるので、ラベルは結び付いた定義の書かれた字から引く（定義の無い参照は、cmark が
        // 地の字に戻す）。
        add("[^" + PrCommentMarkdown.literal(cmark_node_parent_footnote_def(node)) + "]")
        return false
      case CMARK_NODE_HTML_INLINE:
        add(PrCommentMarkdown.literal(node))
        return false
      default:
        if PrCommentMarkdown.typeName(node) == "strikethrough" {
          strike += 1
          return false
        }
        // 表・区切り線ほか描かない記法の段は、書かれた字のまま。インラインなら中身の字のまま。
        if block == nil {
          appendText(raw(node))
          return cmark_node_first_child(node) != nil
        }
        add(PrCommentMarkdown.literal(node))
        return false
      }
    }

    private mutating func exit(_ node: Node) {
      switch cmark_node_get_type(node) {
      case CMARK_NODE_PARAGRAPH:
        end()
      case CMARK_NODE_HEADING:
        strong -= 1
        end()
      case CMARK_NODE_BLOCK_QUOTE, CMARK_NODE_LIST:
        frames.removeLast()
      case CMARK_NODE_ITEM:
        let item = frames.removeLast()
        if blocks.count == item.blocksAtEntry {
          emit(
            PrCommentBlock(
              kind: .text, indent: item.context.indent, quoteBars: item.context.quoteBars,
              markers: [], text: ZoneStyledText(), links: [:], strikes: []))
        }
      case CMARK_NODE_EMPH: emphasis -= 1
      case CMARK_NODE_STRONG: strong -= 1
      case CMARK_NODE_LINK: links.removeLast()
      case CMARK_NODE_IMAGE:
        let url = PrCommentMarkdown.string(cmark_node_get_url(node))
        let title = PrCommentMarkdown.string(cmark_node_get_title(node))
        add("](" + url + (title.isEmpty ? "" : " \"\(title)\"") + ")")
      default:
        if PrCommentMarkdown.typeName(node) == "strikethrough" { strike -= 1 }
      }
    }

    // MARK: - 箇条書き

    /// 箇条書きの入れ物——項目の字下げは、番号付きなら最も広い番号の幅に合わせる（番号は右揃え）。
    private func list(_ node: Node) -> Frame {
      var frame = Frame(node: node, context: context)
      frame.next = Int(cmark_node_get_list_start(node))
      frame.listIndent = Theme.Layout.editorPrBodyListIndent
      guard cmark_node_get_list_type(node) == CMARK_ORDERED_LIST else { return frame }
      // 数字の幅は字ごとに違うので、最後の番号が最も広いとは限らない。
      var child = cmark_node_first_child(node)
      while let item = child {
        frame.numberWidths.append(
          ZoneTextLayout.width([
            ZoneTextRun(
              "\(frame.next + frame.numberWidths.count).",
              font: Theme.Typography.editorPrThreadBody, color: .clear)
          ]))
        child = cmark_node_next(item)
      }
      frame.listIndent = max(
        frame.listIndent,
        (frame.numberWidths.max() ?? 0) + Theme.Layout.editorPrBodyListMarkerGap)
      return frame
    }

    /// 項目に入る——印を次に出す段に積み、字下げを深くする。
    private mutating func item(_ node: Node) {
      guard var list = frames.popLast() else { return }
      let base = list.context
      var inner = base
      let ordered = cmark_node_get_list_type(list.node) == CMARK_ORDERED_LIST
      let text = ordered ? "\(list.next)." : "•"
      let index = list.next - Int(cmark_node_get_list_start(list.node))
      list.next += 1
      frames.append(list)
      if base.depth < PrCommentMarkdown.maxDepth {
        inner.indent += list.listIndent
        inner.depth += 1
      }
      let x: CGFloat
      if ordered {
        let width = list.numberWidths.indices.contains(index) ? list.numberWidths[index] : 0
        x = inner.indent - Theme.Layout.editorPrBodyListMarkerGap - width
      } else {
        x = inner.indent - list.listIndent
      }
      markers.append(PrCommentBlock.Marker(text: text, x: max(base.indent, x)))
      var frame = Frame(node: node, context: inner)
      frame.blocksAtEntry = blocks.count
      frames.append(frame)
    }

    // MARK: - 段と字

    /// 字の段を書き始める。
    private mutating func begin() {
      block = PrCommentBlock(
        kind: .text, indent: context.indent, quoteBars: context.quoteBars, markers: [],
        text: ZoneStyledText(), links: [:], strikes: [])
    }

    /// 書いている字の段を出す。
    private mutating func end() {
      guard let finished = block else { return }
      block = nil
      emit(finished)
    }

    /// 段を出す（積んだ箇条書きの印を付ける）。
    private mutating func emit(_ next: PrCommentBlock) {
      var next = next
      next.markers = markers
      markers = []
      blocks.append(next)
    }

    /// 書かれた字の段を出す。
    private mutating func appendText(_ text: String) {
      begin()
      add(text)
      end()
    }

    /// 地の字。リンクの外では、本文に直接書いた http(s) の URL をリンクにする。
    private mutating func addText(_ string: String) {
      guard links.isEmpty, LinkDetector.mayContainLinks(string.utf16) else {
        return add(string)
      }
      let units = string as NSString
      var location = 0
      for link in LinkDetector.links(in: string) {
        add(
          units.substring(with: NSRange(location: location, length: link.range.location - location))
        )
        links.append(link.url)
        add(units.substring(with: link.range))
        links.removeLast()
        location = NSMaxRange(link.range)
      }
      add(units.substring(from: location))
    }

    /// 字の連なりを、今の見え方で段の後ろに足す。
    private mutating func add(_ string: String) {
      guard !string.isEmpty, block != nil else { return }
      let font =
        strong > 0 ? Theme.Typography.editorPrThreadBodyStrong : Theme.Typography.editorPrThreadBody
      let link = links.last.flatMap { $0 }
      let color =
        link != nil
        ? Theme.Color.accentBright : context.quoted ? Theme.Color.textMuted : Theme.Color.editorText
      mark(at: block!.text.styles.count)
      block!.text.append(
        string, PrCommentMarkdown.style(emphasis > 0 ? PrCommentMarkdown.italic(font) : font, color)
      )
    }

    /// 見え方 `index` の取り消し線とリンクを段に記す。
    private mutating func mark(at index: Int) {
      if strike > 0 { block!.strikes.insert(index) }
      if let link = links.last.flatMap({ $0 }) { block!.links[index] = link }
    }

    private func raw(_ node: Node) -> String {
      PrCommentMarkdown.writtenText(of: node, utf8: utf8, lineStarts: lineStarts)
    }
  }
}

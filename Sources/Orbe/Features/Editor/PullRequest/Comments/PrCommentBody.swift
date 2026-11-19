import AppKit
import OrbeEditorCore

private typealias Size = Theme.Layout
private typealias Ink = Theme.Color
private typealias Fonts = Theme.Typography

/// コメントの本文を本文の幅で組んだもの——組んだ本文の字（同じコメントでも本文が変われば組み直す）と、本文の層（原点は本文の
/// 左上）と、層の高さと、リンクの行き先（本文の中のリンクの押せる場所の通し番号 → URL）。裏のスレッドで組み、main へ渡す。
struct PrCommentBody: Sendable {
  let source: String
  let layer: ZoneLayer
  let height: CGFloat
  let links: [Int: URL]

  /// 本文の行の高さ（字 12・行高 1.6）。
  static let lineHeight = Fonts.editorPrThreadBody.pointSize * Fonts.editorPrThreadBodyLineHeight

  /// コメント `comment` の本文 `source` を段に変換し、本文の幅 `width` で段を組んで層にする（純関数。どのスレッドからも
  /// 呼べる）。段の列は字 12・行高 1.6・段の間 6 で、引用の線は、次の段が同じ引用の線を持てば段の間も引く。仕事は本文の
  /// 長さに比例する。
  static func make(_ source: String, comment: String, width: CGFloat) -> PrCommentBody {
    var parts = Parts(comment: comment, width: width)
    let blocks = PrCommentMarkdown.blocks(source)
    var y: CGFloat = 0
    for (index, block) in blocks.enumerated() {
      if index > 0 { y += Size.editorPrBodyBlockGap }
      let next = index + 1 < blocks.count ? blocks[index + 1].quoteBars : []
      y += parts.add(block, index: index, top: y, joining: next)
    }
    return PrCommentBody(
      source: source, layer: ZoneLayer(elements: parts.elements, texts: parts.texts), height: y,
      links: parts.links)
  }

  /// 段の字の左端の、本文の左端からの距離（字下げと、コードブロックの左の余白）。
  static func textLeft(of block: PrCommentBlock) -> CGFloat {
    block.indent + (block.kind == .code ? Size.editorPrBodyCodePad : 0)
  }

  /// 本文の幅 `width` で、段の字を折り返す幅（字下げと、コードブロックの左右の余白を除く）。
  static func wrapWidth(of block: PrCommentBlock, in width: CGFloat) -> CGFloat {
    max(1, width - block.indent - (block.kind == .code ? Size.editorPrBodyCodePad * 2 : 0))
  }
}

/// 本文の層の要素と選べる文を積む（座標は本文の左上から）。
private struct Parts {
  let comment: String
  let width: CGFloat
  var elements: [ZoneElement] = []
  var texts: [ZoneText] = []
  var links: [Int: URL] = [:]

  init(comment: String, width: CGFloat) {
    self.comment = comment
    self.width = width
  }

  /// 段 `block`（`index` 番目）を上端 `y` に置き、高さを返す。`next` は次の段の引用の線。
  mutating func add(
    _ block: PrCommentBlock, index: Int, top y: CGFloat, joining next: [PrCommentBlock.QuoteBar]
  ) -> CGFloat {
    let lineHeight = PrCommentBody.lineHeight
    let typeset = ZoneTextLayout.typeset(
      block.text, width: PrCommentBody.wrapWidth(of: block, in: width))
    let pad = block.kind == .code ? Size.editorPrBodyCodePad : 0
    let height = CGFloat(max(1, typeset.lines.count)) * lineHeight + pad * 2
    for bar in block.quoteBars {
      let joins = next.contains(bar)
      elements.append(
        .box(
          ZoneBox(
            frame: CGRect(
              x: bar.x, y: y, width: Size.editorPrBodyQuoteBar,
              height: height + (joins ? Size.editorPrBodyBlockGap : 0)),
            fill: EditorStyle.hairline(0.12))))
    }
    if block.kind == .code {
      elements.append(
        .box(
          ZoneBox(
            frame: CGRect(
              x: block.indent, y: y, width: max(0, width - block.indent), height: height),
            radius: .init(Size.editorPrBodyCodeRadius), fill: EditorStyle.sunk(0.35))))
    }
    let font = Fonts.editorPrThreadBody
    for marker in block.markers {
      elements.append(
        .text(
          ZoneTextLine(
            origin: CGPoint(
              x: marker.x,
              y: PrCommentStyle.baseline(top: y + pad, height: lineHeight, font: font)),
            runs: [ZoneTextRun(marker.text, font: font, color: Ink.textMuted)])))
    }
    let left = PrCommentBody.textLeft(of: block)
    let tops = typeset.lines.indices.map { y + pad + CGFloat($0) * lineHeight }
    let baselines = tops.map { PrCommentStyle.baseline(top: $0, height: lineHeight, font: font) }
    decorate(typeset, block, left: left, tops: tops, baselines: baselines)
    texts.append(
      ZoneText(
        id: "\(comment)#\(index)", typeset: typeset,
        origins: baselines.map { CGPoint(x: left, y: $0) }))
    return height
  }

  /// 段の見え方ごとの飾り——インラインコードの地（余白込み・角丸 3）、取り消し線、リンクの押せる場所。飾る見え方だけを文の
  /// 位置の順に並べ、行ごとに、行の範囲に重なる見え方だけを引く（仕事は行の数と飾る見え方の数の和に比例する）。行 `row` の
  /// 上端は `tops[row]`、基線は `baselines[row]`、字の左端は `left`。
  private mutating func decorate(
    _ typeset: ZoneTypeset, _ block: PrCommentBlock, left: CGFloat, tops: [CGFloat],
    baselines: [CGFloat]
  ) {
    var decorated: [(style: Int, range: Range<Int>)] = []
    var end = 0
    for (index, style) in typeset.content.styles.enumerated() {
      let start = end
      end += style.length
      guard start < end,
        style.leadingPadding > 0 || block.strikes.contains(index) || block.links[index] != nil
      else { continue }
      decorated.append((index, start..<end))
    }
    var first = 0
    for (row, line) in typeset.lines.enumerated() {
      let lower = line.range.location
      let upper = NSMaxRange(line.range)
      while first < decorated.count, decorated[first].range.upperBound <= lower { first += 1 }
      var next = first
      while next < decorated.count, decorated[next].range.lowerBound < upper {
        let style = decorated[next].style
        decorate(
          line.spans(of: style), style: style, block,
          at: Row(left: left, top: tops[row], baseline: baselines[row]),
          typeset.content.styles[style])
        next += 1
      }
    }
  }

  /// 行の字の左端・上端・基線。
  private struct Row {
    let left: CGFloat
    let top: CGFloat
    let baseline: CGFloat
  }

  /// 見え方 `index`（見え方 `style`）の地の x 範囲 `spans` に、行 `row` でのその見え方の飾りを置く。
  private mutating func decorate(
    _ spans: [Range<CGFloat>], style index: Int, _ block: PrCommentBlock, at row: Row,
    _ style: ZoneTextStyle
  ) {
    let (left, top, baseline) = (row.left, row.top, row.baseline)
    guard !spans.isEmpty else { return }
    let mono = Fonts.editorPrThreadCode
    if style.leadingPadding > 0 {
      for span in spans {
        elements.append(
          .box(
            ZoneBox(
              frame: CGRect(
                x: left + span.lowerBound, y: baseline - mono.ascender - 1,
                width: span.upperBound - span.lowerBound,
                height: mono.ascender - mono.descender + 2),
              radius: .init(Size.editorPrInlineCodeRadius), fill: Ink.editorPrInlineCode)))
      }
    }
    if block.strikes.contains(index) {
      let y = baseline - CTFontGetXHeight(style.font) / 2
      for span in spans {
        elements.append(
          .box(
            ZoneBox(
              frame: CGRect(
                x: left + span.lowerBound, y: y - 0.5, width: span.upperBound - span.lowerBound,
                height: 1), fill: style.color)))
      }
    }
    if let url = block.links[index] {
      for span in spans {
        let id = links.count
        links[id] = url
        elements.append(
          .button(
            ZoneButton(
              id: PrCommentControl.link(comment: comment, index: id),
              frame: CGRect(
                x: left + span.lowerBound, y: top, width: span.upperBound - span.lowerBound,
                height: PrCommentBody.lineHeight))))
      }
    }
  }
}

/// 本文の幅ごとに組んだコメントの本文を覚え、無ければ裏で組む（→ code.md の「載せる側の作り方」）。絵を問われた幅の覚えが
/// 無い間は、ほかの幅で組んだ同じ本文（仮の層）で絵を組ませ、組み終えたら `done` で描き直させる。覚える幅は最近使った数個だけ。
@MainActor
final class PrCommentBodies {
  /// コメントの id と本文。
  typealias Comment = (id: String, body: String)

  private var byWidth: [CGFloat: [String: PrCommentBody]] = [:]
  /// 覚えた幅（使った時が古い順）。
  private var widths: [CGFloat] = []
  /// 裏で組んでいる幅と、組み終えた後に組みたい幅。
  private var typesetting: CGFloat?
  private var wanted: (width: CGFloat, comments: [Comment])?
  /// 組み終えた（覚えから絵を組めるようになった）。
  var done: () -> Void = {}

  private static let keptWidths = 3

  /// 裏で組んでいる。
  var isTypesetting: Bool { typesetting != nil }

  /// 本文の幅 `width` で組んだコメント `comments` の本文。覚えに無いコメントは裏で組み始め、その間はほかの幅で組んだ同じ
  /// 本文を返す（どの幅でも組んでいなければ返さない）。返した本文の幅が `width` と違うことがある。
  func bodies(_ comments: [Comment], width: CGFloat) -> [String: PrCommentBody] {
    if widths.last != width, let used = widths.firstIndex(of: width) {
      widths.append(widths.remove(at: used))
    }
    let known = byWidth[width] ?? [:]
    let missing = comments.filter { known[$0.id]?.source != $0.body }
    guard !missing.isEmpty else { return known }
    request(missing, width: width)
    var result = known
    for comment in missing {
      result[comment.id] = widths.reversed().lazy.compactMap { [byWidth] in
        byWidth[$0]?[comment.id]
      }.first { $0.source == comment.body }
    }
    return result
  }

  private func request(_ comments: [Comment], width: CGFloat) {
    guard typesetting == nil else {
      wanted = (width, comments)
      return
    }
    typesetting = width
    Task.detached(priority: .userInitiated) { [weak self] in
      let bodies = comments.map {
        ($0.id, PrCommentBody.make($0.body, comment: $0.id, width: width))
      }
      await MainActor.run { [weak self] in self?.store(bodies, width: width) }
    }
  }

  private func store(_ bodies: [(String, PrCommentBody)], width: CGFloat) {
    typesetting = nil
    if byWidth[width] == nil {
      widths.append(width)
      if widths.count > Self.keptWidths { byWidth[widths.removeFirst()] = nil }
    }
    for (id, body) in bodies { byWidth[width, default: [:]][id] = body }
    let next = wanted
    wanted = nil
    if let next {
      let known = byWidth[next.width] ?? [:]
      let missing = next.comments.filter { known[$0.id]?.source != $0.body }
      if !missing.isEmpty { request(missing, width: next.width) }
    }
    done()
  }
}

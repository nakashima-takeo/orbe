import AppKit
import OrbeEditorCore
import STTextView

/// 見えている段落 1 つの geometry。座標は text container 基準（テキスト view の本文の矩形＝ガターの右）。
struct VisibleLine {
  /// 段落の区間（改行込み。UTF-16）。
  let range: NSRange
  /// 段落の文字列（末尾の改行を除く。CR は残る）。
  let text: String
  /// 段落全体の枠（折り返しの行片と末尾の空行を含む）。
  let frame: CGRect
  /// 行片（折り返した各行と、本文が改行で終わるときの末尾の空行）。
  let rows: [Row]

  struct Row {
    let lineFragment: NSTextLineFragment
    /// 段落内の文字区間。
    let characterRange: NSRange
    let frame: CGRect
    /// 本文が改行で終わるときの末尾の空行（次の行の行頭に相当し、文字を持たない）。
    let isExtra: Bool
    /// 描かれた文字のベースラインの y。
    let baseline: CGFloat
  }

  /// 文字を持つ行片の下端（末尾の空行を含まない）。
  var bodyMaxY: CGFloat { rows.filter { !$0.isExtra }.map(\.frame.maxY).max() ?? frame.minY }
  var extraRow: Row? { rows.first { $0.isExtra } }
}

/// viewport の段落を layout manager から毎回取る（エンジン内部の fragment view や座標の写しを持たない）。
/// 文字の縦位置は上流の描画と同じ補正——行高倍率で伸びた行片の中で文字を中央に寄せる——を掛ける。
@MainActor
struct VisibleLines {
  private let textView: STTextView
  private let lineHeightMultiple: CGFloat

  init(textView: STTextView) {
    self.textView = textView
    let multiple = textView.defaultParagraphStyle.lineHeightMultiple
    lineHeightMultiple = multiple > 0 ? multiple : 1
  }

  private var layoutManager: NSTextLayoutManager { textView.textLayoutManager }
  private var contentManager: NSTextContentManager { textView.textContentManager }

  var documentLength: Int {
    NSRange(layoutManager.documentRange, in: contentManager).length
  }

  /// `rect`（container 基準）に掛かる段落。上端の位置に layout が無ければ空（次の layout の通知で描き直す）。
  func lines(in rect: CGRect) -> [VisibleLine] {
    guard rect.height > 0,
      let first = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, rect.minY)))
    else { return [] }
    var result: [VisibleLine] = []
    layoutManager.enumerateTextLayoutFragments(
      from: first.rangeInElement.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
    ) { fragment in
      guard fragment.layoutFragmentFrame.minY < rect.maxY else { return false }
      if fragment.layoutFragmentFrame.maxY > rect.minY { result.append(line(of: fragment)) }
      return true
    }
    return result
  }

  /// 点（container 基準）を含む段落。
  func line(at point: CGPoint) -> VisibleLine? {
    layoutManager.textLayoutFragment(for: point).map(line(of:))
  }

  private func line(of fragment: NSTextLayoutFragment) -> VisibleLine {
    let range = NSRange(fragment.rangeInElement, in: contentManager)
    let frame = fragment.layoutFragmentFrame
    let text = (fragment.textElement as? NSTextParagraph).map(body(of:)) ?? ""
    let rows = fragment.textLineFragments.map { lineFragment -> VisibleLine.Row in
      let bounds = lineFragment.typographicBounds
      let rowFrame = CGRect(
        x: frame.minX + bounds.minX, y: frame.minY + bounds.minY, width: bounds.width,
        height: bounds.height)
      let shift = -(bounds.height * (lineHeightMultiple - 1) / 2)
      return VisibleLine.Row(
        lineFragment: lineFragment, characterRange: lineFragment.characterRange, frame: rowFrame,
        isExtra: lineFragment.characterRange.length == 0 && fragment.textLineFragments.count > 1,
        baseline: rowFrame.minY + shift + lineFragment.glyphOrigin.y)
    }
    return VisibleLine(range: range, text: text, frame: frame, rows: rows)
  }

  /// 段落内の文字位置 `index`（行片の区間の端を含む）の左端の x。
  func x(of index: Int, in row: VisibleLine.Row) -> CGFloat {
    row.frame.minX + row.lineFragment.locationForCharacter(at: index).x
  }

  /// 文字位置を含む行片（区間の終端は次の行片が持つ。末尾は最後の行片）。
  func row(containing index: Int, in line: VisibleLine) -> VisibleLine.Row? {
    line.rows.first { !$0.isExtra && NSLocationInRange(index, $0.characterRange) }
      ?? line.rows.last { !$0.isExtra && NSMaxRange($0.characterRange) == index }
  }

  /// 隣の非空行の文字列（前方 / 後方）。
  func neighbourNonBlank(of line: VisibleLine, forward: Bool) -> String? {
    guard let anchor = NSTextRange(line.range, in: contentManager) else { return nil }
    var found: String?
    contentManager.enumerateTextElements(
      from: forward ? anchor.endLocation : anchor.location, options: forward ? [] : [.reverse]
    ) { element in
      guard let paragraph = element as? NSTextParagraph,
        let elementRange = element.elementRange, elementRange != anchor
      else { return true }
      let text = body(of: paragraph)
      guard !IndentGuides.isBlank(text[...]) else { return true }
      found = text
      return false
    }
    return found
  }

  /// 段落の文字列から末尾の改行をスカラー単位で落とす（CR は行の中身として残す）。`"\r\n"` は Character
  /// 1 個なので、文字単位の `hasSuffix("\n")` では CRLF の段落を取れない。
  private func body(of paragraph: NSTextParagraph) -> String {
    var scalars = paragraph.attributedString.string.unicodeScalars
    if scalars.last == "\n" { scalars.removeLast() }
    return String(scalars)
  }

  struct LinkRun {
    let url: URL
    /// 行片の中でリンクが占める枠。
    let frame: CGRect
    let baseline: CGFloat
    /// 区間の先頭の描画色（rendering attribute。無ければ nil＝素の文字色）。
    let color: NSColor?
  }

  /// 段落の URL を行片ごとの枠に写す（描画・カーソル・⌘クリックの当たりが同じ答えを使う）。
  func links(in line: VisibleLine) -> [LinkRun] {
    LinkDetector.links(in: line.text).flatMap { link -> [LinkRun] in
      let start = link.range.location
      let end = NSMaxRange(link.range)
      let color = renderingColor(at: line.range.location + start)
      return line.rows.compactMap { row in
        guard !row.isExtra else { return nil }
        let rowStart = row.characterRange.location
        let rowEnd = NSMaxRange(row.characterRange)
        let from = max(start, rowStart)
        let to = min(end, rowEnd)
        guard from < to else { return nil }
        let x0 = x(of: from, in: row)
        let x1 = x(of: to, in: row)
        return LinkRun(
          url: link.url,
          frame: CGRect(x: x0, y: row.frame.minY, width: x1 - x0, height: row.frame.height),
          baseline: row.baseline, color: color)
      }
    }
  }

  /// オフセットの字の描画色（rendering attribute の `.foregroundColor`）。無ければ nil。
  private func renderingColor(at offset: Int) -> NSColor? {
    guard
      let location = contentManager.location(layoutManager.documentRange.location, offsetBy: offset)
    else { return nil }
    var color: NSColor?
    let read = { (attributes: [NSAttributedString.Key: Any], range: NSTextRange) -> Bool in
      if range.contains(location) { color = attributes[.foregroundColor] as? NSColor }
      return false
    }
    layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { read($1, $2) }
    return color
  }

  /// 点（container 基準）の下の URL。
  func link(at point: CGPoint) -> URL? {
    guard let line = line(at: point) else { return nil }
    return links(in: line).first { $0.frame.contains(point) }?.url
  }
}

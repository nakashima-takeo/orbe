import Foundation
import OrbeEditorCore

/// 行の装備の素——見せる空白の並び・URL の区間（どれも行内の UTF-16 の位置）。行の中身だけで決まるので、組版の
/// キャッシュが行の中身を鍵に覚え（`LineLayoutCache.read`）、行の中身が変わらない限り作り直さない。規則は Core の純関数
/// （`WhitespaceRuns`・`LinkDetector`）。
struct LineDecor: Sendable {
  var whitespace: [Range<Int>]
  var links: [NSRange]

  /// 読むのは描きうる先頭（`LineShaper.Source`）の UTF-16 単位で、URL を含みうる行だけ字に直して読む（対の片割れは
  /// U+FFFD（1 単位）に読むので、位置はずれない）。
  init(_ source: LineShaper.Source) {
    let line = source.head
    whitespace = WhitespaceRuns.runs(in: line)
    links =
      LinkDetector.mayContainLinks(line)
      ? LinkDetector.links(in: String(decoding: line, as: UTF16.self)).map(\.range) : []
  }

  init(whitespace: [Range<Int>], links: [NSRange]) {
    self.whitespace = whitespace
    self.links = links
  }

  /// 装備の無い行。
  static let empty = LineDecor(whitespace: [], links: [])

  /// 行の段 `range`（行の中の位置の区間）の装備——位置は段の頭から。空白の並びは段の中に切り、URL は切らずに位置だけ
  /// ずらす（段をまたぐ URL の下線は、段ごとに字の縁で切れる）。
  func segment(_ range: Range<Int>) -> LineDecor {
    guard
      range.lowerBound > 0 || whitespace.last.map({ $0.upperBound > range.upperBound }) == true
        || links.contains(where: { NSMaxRange($0) > range.upperBound })
    else { return self }
    let base = range.lowerBound
    return LineDecor(
      whitespace: whitespace.compactMap { run in
        let clipped = run.clamped(to: range)
        return clipped.isEmpty ? nil : (clipped.lowerBound - base)..<(clipped.upperBound - base)
      },
      links: links.filter { NSMaxRange($0) > range.lowerBound && $0.location < range.upperBound }
        .map { NSRange(location: $0.location - base, length: $0.length) })
  }

  /// 字の位置の x が要る（丸点・下線のどちらかがある）。
  var needsCarets: Bool { !whitespace.isEmpty || !links.isEmpty }

  /// 覚える単位の数。
  var weight: Int { 1 + whitespace.count + links.count }
}

/// 行の装備——空白の丸点と、⌘ を押したポインタの下の URL の下線。選択の地・強調の地の上、字の下に描く（選択した範囲でも点は見える）。位置は字を
/// 描いた行の組版から引く。
extension FrameBuilder {
  /// 行 1 つぶんの空白の丸点を描く。`window` は横に見えている字の位置（長い行でも、見えていない丸点は描かない）。
  func drawWhitespace(_ line: LaidOutLine, rowTop: Double, window: ClosedRange<Int>?, _ c: Context)
  {
    let g = c.g
    let originX = c.originX
    let s = g.scale
    guard let carets = line.carets, let window else { return }
    let diameter = Double(c.config.decorations.whitespaceDiameter) * s
    let middle = rowTop + g.lineHeight / 2
    for run in line.decor.whitespace where run.upperBound > window.lowerBound {
      if run.lowerBound > window.upperBound { break }
      for index in max(
        run.lowerBound, window.lowerBound)..<min(run.upperBound, window.upperBound + 1)
      {
        let center = originX + Double(carets.x(index) + carets.x(index + 1)) / 2 * s
        decorShapes.append(
          ShapeInstance(
            rect: SIMD4(
              Float(center - diameter / 2), Float(middle - diameter / 2), Float(diameter),
              Float(diameter)),
            color: c.palette.whitespace.packed, radius: Float(diameter / 2), kind: 0))
      }
    }
  }

  /// ⌘ を押したポインタの下の URL（行 `row` の中の位置。行の段のどれかの字の上にポインタがあれば、その URL）。
  func hoveredLink(in rows: [RowInFrame], row: Int, _ c: Context) -> NSRange? {
    guard let pointer = c.linkPointer else { return nil }
    let g = c.g
    for item in rows where item.row == row {
      let top = g.segmentTop(item.row, item.segment)
      guard pointer.y >= top, pointer.y < top + g.lineHeight, let carets = item.laid.carets else {
        continue
      }
      let originX = c.indented(item.indent).originX
      for link in item.laid.decor.links {
        let left = originX + Double(carets.x(link.location)) * g.scale
        let right = originX + Double(carets.x(NSMaxRange(link))) * g.scale
        if pointer.x >= left, pointer.x < right {
          return NSRange(location: link.location + item.base, length: link.length)
        }
      }
    }
    return nil
  }

  /// URL `link`（行の中の位置）の、段 `row` に掛かる部分に下線を引く。
  func drawLinkUnderline(
    _ row: RowInFrame, link: NSRange, rowTop: Double, window: ClosedRange<Int>?, _ c: Context
  ) {
    let line = row.laid
    let g = c.g
    let originX = c.originX
    let s = g.scale
    let local = NSRange(location: link.location - row.base, length: link.length)
    guard let carets = line.carets, let window, NSMaxRange(local) > window.lowerBound,
      local.location <= window.upperBound, NSMaxRange(local) > 0, local.location < line.length
    else { return }
    let baseline = rowTop + (Double(c.config.baseline) * s).rounded()
    let top = (baseline + Double(c.config.decorations.linkUnderlineOffset) * s).rounded()
    let thickness = max(
      1, (Double(c.config.decorations.linkUnderlineThickness) * s).rounded())
    let left = originX + Double(carets.x(local.location)) * s
    let right = originX + Double(carets.x(NSMaxRange(local))) * s
    let role = c.roles.roles(in: NSRange(location: row.start + link.location, length: 1))
      .first?.role
    decorShapes.append(
      ShapeInstance(
        rect: SIMD4(
          Float(left.rounded()), Float(top), Float(right.rounded() - left.rounded()),
          Float(thickness)),
        color: c.palette.ink(role).color.packed, radius: 0, kind: 0))
  }
}

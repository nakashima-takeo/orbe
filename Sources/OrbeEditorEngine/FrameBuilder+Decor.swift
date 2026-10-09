import Foundation
import OrbeEditorCore

/// 行の装備の素——見せる空白の並び・URL の区間（どれも行内の UTF-16 の位置）。行の中身だけで決まるので、組版と一緒に
/// 覚え、行の中身が変わらない限り作り直さない。規則は Core の純関数（`WhitespaceRuns`・`LinkDetector`）。
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
    let originX = g.column - g.scrollX
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

  /// ⌘ を押したポインタの下の URL に下線を引く（文書の行 1 つ）。
  func drawLinkUnderline(
    _ row: RowInFrame, rowTop: Double, window: ClosedRange<Int>?, _ c: Context
  ) {
    let line = row.laid
    let g = c.g
    let originX = g.column - g.scrollX
    let s = g.scale
    guard let carets = line.carets, let window, let pointer = c.linkPointer,
      pointer.y >= rowTop, pointer.y < rowTop + g.lineHeight
    else { return }
    let baseline = rowTop + (Double(c.config.baseline) * s).rounded()
    let top = (baseline + Double(c.config.decorations.linkUnderlineOffset) * s).rounded()
    let thickness = max(
      1, (Double(c.config.decorations.linkUnderlineThickness) * s).rounded())
    for link in line.decor.links
    where NSMaxRange(link) > window.lowerBound && link.location <= window.upperBound {
      let left = originX + Double(carets.x(link.location)) * s
      let right = originX + Double(carets.x(NSMaxRange(link))) * s
      guard pointer.x >= left, pointer.x < right else { continue }
      let role = c.roles.roles(in: NSRange(location: row.start + link.location, length: 1))
        .first?.role
      decorShapes.append(
        ShapeInstance(
          rect: SIMD4(
            Float(left.rounded()), Float(top), Float(right.rounded() - left.rounded()),
            Float(thickness)),
          color: c.palette.ink(role).color.packed, radius: 0, kind: 0))
      return
    }
  }
}

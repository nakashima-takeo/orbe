import Foundation
import OrbeEditorCore

/// 行の装備の素——インデントの段の境・空白だけの行か・見せる空白の並び・URL の区間（どれも行内の UTF-16 の位置）。行の
/// 中身とインデントの単位だけで決まるので、組版と一緒に覚え、行の中身が変わらない限り作り直さない。規則は Core の純関数
/// （`IndentGuides`・`WhitespaceRuns`・`LinkDetector`）。
struct LineDecor: Sendable {
  var boundaries: [Int]
  var blank: Bool
  var whitespace: [Range<Int>]
  var links: [NSRange]

  /// 読むのは描きうる先頭（`LineShaper.Source`）。対の片割れは U+FFFD（1 単位）に読むので、位置はずれない。
  init(_ source: LineShaper.Source, unit: Int) {
    let line = String(decoding: source.head, as: UTF16.self)
    boundaries = IndentGuides.boundaries(of: line[...], unit: unit)
    blank = source.head.count == source.length && IndentGuides.isBlank(line[...])
    whitespace = WhitespaceRuns.runs(in: line[...])
    links = LinkDetector.links(in: line).map(\.range)
  }

  /// 字の位置の x が要る（段の境の線・丸点・下線のどれかがある）。
  var needsCarets: Bool { !boundaries.isEmpty || !whitespace.isEmpty || !links.isEmpty }

  /// 覚える単位の数。
  var weight: Int { 1 + boundaries.count + whitespace.count + links.count }
}

/// 行の装備——インデント線・空白の丸点・URL の下線。選択の地・強調の地・字より下に描く（選択の地が装備を覆う）。位置は字を
/// 描いた行の組版から引く。
extension FrameBuilder {
  /// 行 1 つぶんの装備を描く。`level` はインデント線の段の数（空白だけの行は前後の非空行の浅い方）。`window` は横に
  /// 見えている字の位置（長い行でも、見えていない丸点と下線は描かない）。
  func drawDecor(
    _ row: RowInFrame, level: Int, rowTop: Double, window: ClosedRange<Int>?, _ c: Context
  ) {
    let line = row.laid
    let start = row.start
    guard let decor = line.decor else { return }
    let g = c.g
    let originX = g.column - g.scrollX
    let s = g.scale
    let bottom = rowTop + g.lineHeight.rounded()
    let unit = c.tabColumns
    let guideWidth = Double(c.config.decorations.indentGuideWidth)
    for k in 0..<level {
      let x: Double
      if k < decor.boundaries.count, let carets = line.carets {
        x = Double(carets.x(decor.boundaries[k]))
      } else {
        x = Double((k + 1) * unit) * Double(c.config.cell)
      }
      let left = (originX + x * s).rounded()
      let right = (originX + (x + guideWidth) * s).rounded()
      guard right > g.column, left < g.textRight else { continue }
      decorShapes.append(
        ShapeInstance(
          rect: SIMD4(
            Float(left), Float(rowTop), Float(max(1, right - left)), Float(bottom - rowTop)),
          color: c.palette.indentGuide.packed, radius: 0, kind: 0))
    }
    guard let carets = line.carets, let window else { return }
    let diameter = Double(c.config.decorations.whitespaceDiameter) * s
    let middle = rowTop + g.lineHeight / 2
    for run in decor.whitespace where run.upperBound > window.lowerBound {
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
    let baseline = rowTop + (Double(c.config.baseline) * s).rounded()
    let top = (baseline + Double(c.config.decorations.linkUnderlineOffset) * s).rounded()
    let thickness = max(
      1, (Double(c.config.decorations.linkUnderlineThickness) * s).rounded())
    for link in decor.links
    where NSMaxRange(link) > window.lowerBound && link.location <= window.upperBound {
      let role = c.roles.roles(in: NSRange(location: start + link.location, length: 1)).first?.role
      let ink = role.flatMap { c.palette.roles[$0] } ?? c.palette.text
      let left = (originX + Double(carets.x(link.location)) * s).rounded()
      let right = (originX + Double(carets.x(NSMaxRange(link))) * s).rounded()
      decorShapes.append(
        ShapeInstance(
          rect: SIMD4(Float(left), Float(top), Float(right - left), Float(thickness)),
          color: ink.packed, radius: 0, kind: 0))
    }
  }

  /// 見えている行（`laid` は `first` 行目から順）のインデント線の段の数。空白だけの行は前後の非空行の浅い方（片側が
  /// 無ければ 0）で、見えている範囲の外の非空行は上下の端から 1 回ずつ探す（空行の並びで共有する）。
  static func indentLevels(
    _ laid: [LaidOutLine], first: Int, text: TextRope, unit: Int
  ) -> [Int] {
    let levels = laid.map { $0.decor.map { $0.blank ? nil : $0.boundaries.count } ?? 0 }
    guard levels.contains(where: { $0 == nil }) else { return levels.map { $0 ?? 0 } }
    var above: [Int?] = []
    var previous = nonBlankLevel(from: first - 1, step: -1, text: text, unit: unit)
    for level in levels {
      above.append(previous)
      if let level { previous = level }
    }
    var below = [Int?](repeating: nil, count: levels.count)
    var next = nonBlankLevel(from: first + levels.count, step: 1, text: text, unit: unit)
    for index in levels.indices.reversed() {
      below[index] = next
      if let level = levels[index] { next = level }
    }
    return levels.indices.map { index in
      if let level = levels[index] { return level }
      guard let up = above[index], let down = below[index] else { return 0 }
      return min(up, down)
    }
  }

  /// `row` から `step` の向きへ最初の空白だけでない行の段の数（無ければ nil）。行頭の空白だけを読む。
  private static func nonBlankLevel(from row: Int, step: Int, text: TextRope, unit: Int) -> Int? {
    var row = row
    while row >= 0, row < text.lineCount {
      let start = text.lineStart(row)
      let end = text.lineEnd(row)
      let units = text.units(in: NSRange(location: start, length: min(end - start, 4096)))
      let first = units.firstIndex { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D && $0 != 0x0A }
      if first != nil || units.count < end - start {
        let leading = String(decoding: units[..<(first ?? units.count)], as: UTF16.self)
        return IndentGuides.boundaries(of: (leading + "x")[...], unit: unit).count
      }
      row += step
    }
    return nil
  }
}

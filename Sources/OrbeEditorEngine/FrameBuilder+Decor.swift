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
    let decor = line.decor
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
      let ink = c.palette.ink(role)
      let left = (originX + Double(carets.x(link.location)) * s).rounded()
      let right = (originX + Double(carets.x(NSMaxRange(link))) * s).rounded()
      decorShapes.append(
        ShapeInstance(
          rect: SIMD4(Float(left), Float(top), Float(right - left), Float(thickness)),
          color: ink.packed, radius: 0, kind: 0))
    }
  }

  /// 見えている行（`laid` は `first` 行目から順）のインデント線の段の数。規則は `IndentGuides.levels` で、見えている
  /// 範囲の外の非空行の段は、端の行が空白だけのときだけ、覚えた空行の塊から引く。
  func indentLevels(_ laid: [LaidOutLine], first: Int, content: SurfaceContent, unit: Int) -> [Int]
  {
    let levels = laid.map { $0.decor.blank ? nil : $0.decor.boundaries.count }
    let edge = { (index: Int?, row: Int) -> BlankBlocks.Around? in
      guard let index, levels[index] == nil else { return nil }
      return self.blankBlocks.around(row, in: content.text, version: content.version, unit: unit)
    }
    let top = edge(levels.indices.first, first)
    let bottom = edge(levels.indices.last, first + levels.count - 1)
    return IndentGuides.levels(levels, above: top?.above, below: bottom?.below)
  }
}

/// 空白だけの行（`LineDecor.blank` と同じ判定——行の中身が描きうる先頭に収まり、スペース・タブ・CR だけ）の塊の端と、
/// その上下の外の非空行の段を、本文の版とインデントの単位ごとに覚える（最近の 2 つ）。空行が長く続く文書でも、塊を
/// 歩くのは版が変わったときだけで、歩くときも単位を塊ごとに読む。
final class BlankBlocks {
  /// 塊の上下の外で最も近い非空行の段（無ければ nil）。
  struct Around {
    var above: Int?
    var below: Int?
  }

  private struct Block {
    var rows: ClosedRange<Int>
    var around: Around
  }

  private var version: Int?
  private var unit: Int?
  private var blocks: [Block] = []
  /// 1 回に読む単位の数。
  private static let stride = 4096

  /// 空白だけの行 `row` を含む塊の、上下の外の非空行の段。
  func around(_ row: Int, in text: TextRope, version: Int, unit: Int) -> Around {
    if version != self.version || unit != self.unit {
      blocks.removeAll()
      self.version = version
      self.unit = unit
    }
    if let block = blocks.first(where: { $0.rows.contains(row) }) { return block.around }
    let above = Self.nonBlankAbove(row, in: text)
    let below = Self.nonBlankBelow(row, in: text)
    let level = { (row: Int) in
      let head = LineShaper.source(row: row, in: text).source.head
      return IndentGuides.boundaries(of: String(decoding: head, as: UTF16.self)[...], unit: unit)
        .count
    }
    let block = Block(
      rows: (above.map { $0 + 1 } ?? 0)...(below.map { $0 - 1 } ?? text.lineCount - 1),
      around: Around(above: above.map(level), below: below.map(level)))
    blocks = [block] + blocks.prefix(1)
    return block.around
  }

  /// 空白だけの中身の長さ `length`（行末の改行と `\r` を除く）が描きうる先頭に収まる——収まらない行は空白だけの行と
  /// 見なさない（`LineDecor.blank` と同じ）。
  private static func fits(_ length: Int) -> Bool { length <= LineShaper.headLimit }

  /// 空白だけの行 `row` より下で最も近い、空白だけでない行（無ければ nil）。
  private static func nonBlankBelow(_ row: Int, in text: TextRope) -> Int? {
    var current = row + 1
    guard current < text.lineCount else { return nil }
    var offset = text.lineStart(current)
    var lineStart = offset
    var previous: UInt16 = 0
    while offset < text.length {
      for unit in text.units(in: NSRange(location: offset, length: stride)) {
        if unit == 0x0A {
          let length = offset - lineStart - (offset > lineStart && previous == 0x0D ? 1 : 0)
          guard fits(length) else { return current }
          current += 1
          lineStart = offset + 1
        } else if !IndentGuides.isBlank(unit: unit) {
          return current
        }
        previous = unit
        offset += 1
      }
    }
    let length = offset - lineStart - (offset > lineStart && previous == 0x0D ? 1 : 0)
    return fits(length) ? nil : current
  }

  /// 空白だけの行 `row` より上で最も近い、空白だけでない行（無ければ nil）。
  private static func nonBlankAbove(_ row: Int, in text: TextRope) -> Int? {
    var current = row - 1
    guard current >= 0 else { return nil }
    var lineEnd = text.lineStart(row) - 1
    var offset = lineEnd
    var last: UInt16?
    while true {
      let from = max(0, offset - stride)
      let units = text.units(in: NSRange(location: from, length: offset - from))
      for unit in units.reversed() {
        offset -= 1
        if unit == 0x0A {
          let length = lineEnd - offset - 1 - (last == 0x0D ? 1 : 0)
          guard fits(length) else { return current }
          current -= 1
          lineEnd = offset
          last = nil
        } else if !IndentGuides.isBlank(unit: unit) {
          return current
        } else if last == nil {
          last = unit
        }
      }
      guard offset > 0 else { break }
    }
    return fits(lineEnd - (last == 0x0D ? 1 : 0)) ? nil : current
  }
}

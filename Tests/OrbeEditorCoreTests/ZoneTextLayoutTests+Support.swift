import AppKit
import XCTest

@testable import OrbeEditorCore

extension ZoneTextLayoutTests {
  /// 部分 `parts` のうち `codes` をコード（余白 `padding` の等幅）、ほかを本文の字体にした見え方。`codes` を省けば真ん中の
  /// 1 つだけがコード。
  func styles(_ parts: [String], codes: [Int]? = nil, padding: CGFloat) -> [ZoneTextStyle] {
    let codes = codes ?? [1]
    return parts.enumerated().map { index, part in
      codes.contains(index)
        ? ZoneTextStyle(length: part.utf16.count, font: mono, color: .red, padding: padding)
        : ZoneTextStyle(length: part.utf16.count, font: font, color: .white)
    }
  }

  /// 部分 `parts` を幅 `width` で組み、コード `code` の地が守らない約束を返す（→ `misplaced`）。
  func check(
    _ parts: [String], code: Int, width: CGFloat, codes: [Int]? = nil, measuresPadding: Bool = true
  ) -> [String] {
    let string = parts.joined()
    let lines = ZoneTextLayout.lines(
      string, styles: styles(parts, codes: codes ?? [code], padding: padding), width: width)
    let start = parts[..<code].reduce(0) { $0 + $1.utf16.count }
    let end = start + parts[code].utf16.count
    var wrong: [String] = []
    for line in lines {
      let edges =
        (NSLocationInRange(start, line.range) ? 1 : 0)
        + (line.range.location < end && end <= NSMaxRange(line.range) ? 1 : 0)
      wrong += misplaced(line, code: code, edges: measuresPadding ? edges : nil).map {
        "\(string) の幅 \(width) の行 \(line.range): \($0)"
      }
    }
    return wrong
  }

  /// 行 `line` でコード `code` の地が守らない約束——地は 1 つの続いた範囲で、コードの字を含み、字より余白 `edges` 個分だけ
  /// 広く（コードの端がこの行にある数。nil なら幅を問わない）、ほかの見え方の字にかぶらない。
  func misplaced(_ line: ZoneTextLayout.Line, code: Int, edges: Int? = 2) -> [String] {
    let spans = line.spans(of: code)
    guard let glyphs = glyphs(of: code, in: line) else {
      return spans.count > 1 ? ["字の無い行で地が \(spans.count) 個"] : []
    }
    guard spans.count == 1, let ground = spans.first else { return ["地が \(spans.count) 個"] }
    var wrong: [String] = []
    let extra = (ground.upperBound - ground.lowerBound) - (glyphs.upperBound - glyphs.lowerBound)
    if let edges, abs(extra - CGFloat(edges) * padding) > 0.01 { wrong.append("余白の合計 \(extra)") }
    if ground.lowerBound > glyphs.lowerBound + 0.01 || ground.upperBound < glyphs.upperBound - 0.01 {
      wrong.append("地 \(ground) が字 \(glyphs) を含まない")
    }
    for glyph in extents(in: line)
    where glyph.style != code && glyph.x.lowerBound < ground.upperBound - 0.01
      && glyph.x.upperBound > ground.lowerBound + 0.01
    {
      wrong.append("見え方 \(glyph.style) の字 \(glyph.x) が地 \(ground) にかぶる")
    }
    return wrong
  }

  /// 見え方 `style` の元の文の字のグリフの x 範囲を結んだもの（グリフが無ければ nil）。
  func glyphs(of style: Int, in line: ZoneTextLayout.Line) -> Range<CGFloat>? {
    let all = extents(in: line).filter { $0.style == style }.map(\.x)
    guard let lower = all.map(\.lowerBound).min(), let upper = all.map(\.upperBound).max() else {
      return nil
    }
    return lower..<upper
  }

  /// 行の、元の文の字のグリフごとの見え方と、組んだ送りでの x 範囲（幅 0 のもの・行末の空白・包みの字は除く）。包みの字は、
  /// 元の文の位置が次の字と同じ字（包みの頭と尾）と、段落の終わりを指す字（段落の末尾の包みの尾）。
  func extents(in line: ZoneTextLayout.Line) -> [(style: Int, x: Range<CGFloat>)] {
    let composition = line.composition
    let hanging = line.hangingStart
    var result: [(style: Int, x: Range<CGFloat>)] = []
    line.forEachGlyph { index, x in
      let offset = composition.original(index)
      guard index < hanging, !x.isEmpty, offset != composition.original(index + 1),
        offset < composition.paragraph.upperBound
      else { return }
      result.append((Int(composition.owners[index]), x))
    }
    return result
  }

  func glyphCount(_ line: ZoneTextLayout.Line) -> Int {
    line.runs.reduce(0) { $0 + $1.glyphs.count }
  }
}

/// 決まった種から決まった列を出す乱数（SplitMix64）。
struct SplitMix {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next(_ bound: Int) -> Int {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return Int((z ^ (z >> 31)) % UInt64(bound))
  }
}

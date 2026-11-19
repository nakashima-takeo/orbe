import AppKit
import XCTest

@testable import OrbeEditorCore

extension ZoneTextLayoutTests {
  /// 部分 `parts` を順に足し、`codes` をコード（余白 `padding` の等幅）、ほかを本文の字体にした見え方つきの文。`codes` を
  /// 省けば真ん中の 1 つだけがコード。
  func styled(_ parts: [String], codes: [Int]? = nil, padding: CGFloat) -> ZoneStyledText {
    let codes = codes ?? [1]
    return ZoneStyledText(
      parts.enumerated().map { index, part in
        (
          part,
          codes.contains(index)
            ? ZoneTextStyle(font: mono, color: .red, padding: padding)
            : ZoneTextStyle(font: font, color: .white)
        )
      })
  }

  /// 部分 `parts` を幅 `width` で組み、コード `code` の地が守らない約束を返す（→ `misplaced`）。
  func check(
    _ parts: [String], code: Int, width: CGFloat, codes: [Int]? = nil, measuresPadding: Bool = true
  ) -> [String] {
    let string = parts.joined()
    let lines = ZoneTextLayout.typeset(
      styled(parts, codes: codes ?? [code], padding: padding), width: width)
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
  func misplaced(_ line: ZoneTextLayout.TypesetLine, code: Int, edges: Int? = 2) -> [String] {
    let spans = line.spans(of: code)
    guard let glyphs = glyphs(of: code, in: line) else {
      return spans.count > 1 ? ["字の無い行で地が \(spans.count) 個"] : []
    }
    guard spans.count == 1, let ground = spans.first else { return ["地が \(spans.count) 個"] }
    var wrong: [String] = []
    let extra = (ground.upperBound - ground.lowerBound) - (glyphs.upperBound - glyphs.lowerBound)
    if let edges, abs(extra - CGFloat(edges) * padding) > 0.01 { wrong.append("余白の合計 \(extra)") }
    if ground.lowerBound > glyphs.lowerBound + 0.01 || ground.upperBound < glyphs.upperBound - 0.01
    {
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
  func glyphs(of style: Int, in line: ZoneTextLayout.TypesetLine) -> Range<CGFloat>? {
    let all = extents(in: line).filter { $0.style == style }.map(\.x)
    guard let lower = all.map(\.lowerBound).min(), let upper = all.map(\.upperBound).max() else {
      return nil
    }
    return lower..<upper
  }

  /// 行の、元の文の字のグリフごとの見え方と、組んだ送りでの x 範囲（幅 0 のもの・行末の空白・包みの字は除く）。包みの字は、
  /// 元の文の位置が次の字と同じ字（包みの頭と尾）と、段落の終わりを指す字（段落の末尾の包みの尾）。
  func extents(in line: ZoneTextLayout.TypesetLine) -> [(style: Int, x: Range<CGFloat>)] {
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

  /// 部分 `parts` を余白なしで（字体だけを付けて）組んだ組版——行を割れる位置の手本。`codes` は等幅の字体。
  func bareTypesetter(_ parts: [String], codes: [Int]) -> CTTypesetter {
    let attributed = NSMutableAttributedString()
    for (index, part) in parts.enumerated() {
      attributed.append(
        NSAttributedString(string: part, attributes: [.font: codes.contains(index) ? mono : font]))
    }
    return CTTypesetterCreateWithAttributedString(attributed)
  }

  /// 組版 `typesetter`（文の長さ `count`）で、行の頭 `start` から組むと、どれかの幅で `end` で割れるか。Core Text は約物を
  /// 詰めて字の幅より狭い幅にも行を収め、禁則のために字の幅より広い幅でだけその位置を選ぶこともあり、答えは幅について単調で
  /// ないので、0 から残りの字の幅までを見る（まず字の幅の前後を細かく、無ければ全体を）。
  func breaks(_ typesetter: CTTypesetter, count: Int, from start: Int, at end: Int) -> Bool {
    let width = { (end: Int) -> Double in
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: end - start))
      return CTLineGetTypographicBounds(line, nil, nil, nil)
        - CTLineGetTrailingWhitespaceWidth(line)
    }
    let fitted = width(end)
    let answers = { (widths: StrideThrough<Double>) in
      widths.contains { start + CTTypesetterSuggestLineBreak(typesetter, start, $0) == end }
    }
    return answers(stride(from: max(0, fitted - 2), through: fitted + 2, by: 0.02))
      || answers(stride(from: 0, through: width(count) + 2, by: 0.1))
  }

  func glyphCount(_ line: ZoneTextLayout.TypesetLine) -> Int {
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

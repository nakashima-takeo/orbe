import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面が組んだ選べる文の使い回し——描き直しで組んだ段落を使い回しても、描く材料と当たりの行は組み直したものと同じ。壊れると、
/// 載せる側が文・字体・余白・行の範囲を変えたのに前の字が描かれたまま残ったり、外観を変えても字の色が前の外観のまま残ったりする。
extension SurfaceZonesTests {
  /// 選べる文の絵を乱択で作り、文・見え方の字体・余白・長さ・色・行の範囲・行の原点・外観のどれか 1 つを変えて（または何も
  /// 変えずに）面で描き直すと、描く材料と当たりの行は、その絵を何も覚えていない写しで描いたものと一致する。
  func testRedrawingAZoneTextDrawsTheSameAsPaintingItAfresh() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    var picture = ZonePicture(height: 0)
    let zone = PictureZone { _ in picture }
    var random = SplitMix(seed: 0x7e57)
    var wrong: [String] = []
    for round in 0..<300 {
      let content = Self.randomText(&random)
      let width = CGFloat(Int.random(in: 60...260, using: &random))
      picture = Self.picture(content, width: width)
      if round == 0 { surface.setRows(self.zone(zone, at: 2)) } else { surface.redrawZone(zone) }
      let change = Int.random(in: 0...8, using: &random)
      if change == 8 {
        let dark = surface.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        surface.textView.appearance = NSAppearance(named: dark == .darkAqua ? .aqua : .darkAqua)
      } else {
        picture = Self.changed(picture, change, &random)
        surface.redrawZone(zone)
      }
      let entry = try XCTUnwrap(surface.zones[ObjectIdentifier(zone)])
      let look = ZonePainter.Look(
        appearance: surface.textView.effectiveAppearance, space: surface.space, scale: surface.scale
      )
      let (material, hits) = ZonePainter().paint(picture, look) { _ in 0 }
      if let difference = Self.difference(entry.material, entry.hits, material, hits) {
        wrong.append("回 \(round)・変えたもの \(change): \(difference)")
      }
    }
    XCTAssertEqual(wrong.prefix(5), [])
  }

  /// 本文の字とインラインコードを乱択で混ぜた見え方つきの文（長さ 0 の見え方も混ぜる）。
  static func randomText(_ random: inout SplitMix) -> ZoneStyledText {
    let words = ["see ", "the ", "שלום ", "漢字", "merges(event)", "กำ", "abc", " ", "、", "x", "\n"]
    var content = ZoneStyledText()
    for _ in 0..<Int.random(in: 2...8, using: &random) {
      let part = words[Int.random(in: 0..<words.count, using: &random)]
      let coded = Bool.random(using: &random)
      content.append(
        part,
        ZoneTextStyle(
          font: coded ? mono : body, color: coded ? .systemRed : .labelColor,
          padding: coded ? 4 : 0))
      if Int.random(in: 0..<6, using: &random) == 0 {
        content.append("", ZoneTextStyle(font: big, color: .labelColor))
      }
    }
    return content
  }

  /// 文の UTF-16 の単位 `units` を、長さ `lengths` ずつ見え方 `styles` で足した見え方つきの文。
  static func content(_ units: [UInt16], _ styles: [ZoneTextStyle], _ lengths: [Int])
    -> ZoneStyledText
  {
    var start = 0
    return ZoneStyledText(
      zip(styles, lengths).map { style, length in
        defer { start += length }
        return (String(decoding: units[start..<start + length], as: UTF16.self), style)
      })
  }

  static let body = NSFont.systemFont(ofSize: 12)
  static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static let big = NSFont.systemFont(ofSize: 15)

  /// 文を幅 `width` で測った行の範囲を、選べる字の行に並べた絵。
  static func picture(_ content: ZoneStyledText, width: CGFloat) -> ZonePicture {
    let lines = ZoneTextLayout.lines(content, width: width).enumerated().map {
      ZoneSelectableLine(
        origin: CGPoint(x: 8, y: 14 + 16 * CGFloat($0.offset)), range: $0.element.range)
    }
    return ZonePicture(
      height: 16 * CGFloat(lines.count) + 8,
      texts: [ZoneText(id: "body", content: content, lines: lines)])
  }

  /// 絵 `picture` の選べる文の 1 つを変えたもの（0: 変えない、1: 色、2: 字体、3: 余白、4: 隣り合う見え方の境、5: 字、
  /// 6: 幅を変えて測り直した行の範囲、7: 行の原点）。1〜5 は行の範囲を変えない。
  static func changed(_ picture: ZonePicture, _ change: Int, _ random: inout SplitMix)
    -> ZonePicture
  {
    var text = picture.texts[0]
    var units = Array(text.content.string.utf16)
    var styles = text.content.styles
    var lengths = styles.map(\.length)
    let index = Int.random(in: 0..<styles.count, using: &random)
    switch change {
    case 1: styles[index].color = .systemBlue
    case 2:
      styles[index].font = (styles[index].font == big as CTFont ? body : big) as CTFont
    case 3:
      styles[index].leadingPadding = styles[index].leadingPadding == 0 ? 3 : 0
      styles[index].trailingPadding = 2
    case 4:
      if index + 1 < styles.count, lengths[index] > 0 {
        lengths[index] -= 1
        lengths[index + 1] += 1
      }
    case 5:
      if let at = units.indices.filter({ units[$0] < 0x80 && units[$0] != 0x0A }).randomElement(
        using: &random)
      {
        units[at] = units[at] == 0x57 ? 0x69 : 0x57
      }
    case 6:
      return Self.picture(
        text.content, width: CGFloat(Int.random(in: 60...260, using: &random)))
    case 7:
      text.lines = text.lines.map {
        ZoneSelectableLine(origin: CGPoint(x: $0.origin.x + 3, y: $0.origin.y + 1), range: $0.range)
      }
    default: break
    }
    text.content = Self.content(units, styles, lengths)
    var next = picture
    next.texts = [text]
    return next
  }

  /// 描く材料（字の連なり）と当たりの行の、最初の食い違い（無ければ nil）。
  static func difference(
    _ material: ZoneMaterial, _ hits: ZoneHits, _ expected: ZoneMaterial, _ expectedHits: ZoneHits
  ) -> String? {
    guard material.runs.count == expected.runs.count else {
      return "字の連なりの数 \(material.runs.count) ≠ \(expected.runs.count)"
    }
    for (index, (a, b)) in zip(material.runs, expected.runs).enumerated() {
      guard CFEqual(a.font, b.font), a.glyphs == b.glyphs, a.xs == b.xs, a.ys == b.ys,
        a.baseline == b.baseline, a.ink == b.ink
      else { return "字の連なり \(index)" }
    }
    guard hits.lines.count == expectedHits.lines.count else {
      return "当たりの行の数 \(hits.lines.count) ≠ \(expectedHits.lines.count)"
    }
    for (index, (a, b)) in zip(hits.lines, expectedHits.lines).enumerated() {
      guard a.range == b.range, a.origin == b.origin, a.ascent == b.ascent, a.descent == b.descent,
        a.layout.width == b.layout.width
      else { return "当たりの行 \(index)" }
    }
    return nil
  }
}

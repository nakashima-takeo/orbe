import AppKit
import XCTest

@testable import OrbeEditorCore

@testable import OrbeEditorEngine

/// 絵の層——描き直した絵が前の絵と同じ層（同じ参照）を持ち、外観が同じなら、面はその層を写し直さず、原点が変わっても材料と
/// 当たりの表を使い回す。点は層の原点を引いた層の座標で引く。壊れると、ホバーの描き直しのたびに長い本文を写し直して main が
/// 止まる・上のコメントの高さが変わると下のコメントの字・押せる場所・選択の地がずれる・外観を変えても前の色が残る。
extension SurfaceZonesTests {
  /// 描き直しのたびに作る頭の層と本文の層を重ねた絵を、本文の層をそのまま・原点だけ動かして・同じ中身の別の参照に替えて・
  /// 文を替えて描き直すか、外観を変えると、描く材料と当たりの表は、何も覚えていない写しで描いたものと一致する。本文の層を
  /// 写し直さないのは、同じ参照で外観が同じとき（そのままと、原点だけ動かしたとき）だけ。
  func testRedrawingReusesTheSameLayerAndDrawsTheSameAsPaintingAfresh() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    var random = SplitMix(seed: 0x1a7e)
    var body = Self.bodyLayer(Self.randomText(&random), width: 200)
    var origin = CGPoint(x: 30, y: 40)
    let zone = PictureZone { _ in
      ZonePicture(height: 400, layers: [(.zero, Self.headLayer()), (origin, body)])
    }
    surface.setRows(self.zone(zone, at: 2))
    var wrong: [String] = []
    for round in 0..<120 {
      let entry = try XCTUnwrap(surface.zones[ObjectIdentifier(zone)])
      let former = entry.material.layers[1].layer.boxes
      let change = Int.random(in: 0...4, using: &random)
      switch change {
      case 1: origin.y += CGFloat(Int.random(in: -10...10, using: &random))
      case 2: body = ZoneLayer(elements: body.elements, texts: body.texts)
      case 3:
        body = Self.bodyLayer(
          Self.randomText(&random), width: CGFloat(Int.random(in: 60...260, using: &random)))
      case 4:
        let dark = surface.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        surface.textView.appearance = NSAppearance(named: dark == .darkAqua ? .aqua : .darkAqua)
      default: break
      }
      if change != 4 { surface.redrawZone(zone) }
      let look = ZonePainter.Look(
        appearance: surface.textView.effectiveAppearance, space: surface.space, scale: surface.scale
      )
      let fresh = ZonePainter().paint(entry.picture, look) { _ in 0 }
      if let difference = Self.difference(entry.material, entry.hits, fresh.material, fresh.hits) {
        wrong.append("回 \(round)・変えたもの \(change): \(difference)")
      }
      let reused = Self.storage(entry.material.layers[1].layer.boxes) == Self.storage(former)
      if reused != (change <= 1) {
        wrong.append("回 \(round)・変えたもの \(change): 本文の層を使い回したか \(reused)")
      }
    }
    XCTAssertEqual(wrong.prefix(5), [])
  }

  /// 点は層の原点を引いた層の座標で引く——どの層の押せる場所・選べる文にも、その層の原点からの位置で当たり、層の間の空きは
  /// ほかに当たらない所になる。選択の地も、選べる文の層の原点だけずれた所に塗る。
  func testPointsHitEachLayerAtItsOrigin() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let button = { (id: String) in
      ZoneLayer(elements: [
        .button(ZoneButton(id: id, frame: CGRect(x: 0, y: 0, width: 100, height: 20)))
      ])
    }
    let string = "下の層の選べる文"
    let text = ZoneLayer(texts: [
      ZoneText.laid("t", ThreadZone.content(string), origin: CGPoint(x: 10, y: 14))
    ])
    let zone = PictureZone { _ in
      ZonePicture(
        height: 120,
        layers: [
          (.zero, button("a")), (CGPoint(x: 0, y: 40), button("b")), (CGPoint(x: 20, y: 80), text),
        ])
    }
    surface.setRows(self.zone(zone, at: 4))
    let point = { (local: CGPoint) in self.viewPoint(surface, zone, local) }
    guard case .button(_, let a) = surface.target(at: point(CGPoint(x: 50, y: 10))) else {
      return XCTFail("上の層の押せる場所")
    }
    XCTAssertEqual(a.id, "a")
    guard case .button(_, let b) = surface.target(at: point(CGPoint(x: 50, y: 50))) else {
      return XCTFail("原点を下げた層の押せる場所")
    }
    XCTAssertEqual(b.id, "b")
    XCTAssertEqual(b.frame, CGRect(x: 0, y: 40, width: 100, height: 20), "矩形は絵の差し込みの座標")
    guard case .zoneSpace = surface.target(at: point(CGPoint(x: 50, y: 30))) else {
      return XCTFail("層の間の空き")
    }
    guard
      case .zoneText(_, let id, let offset) = surface.target(at: point(CGPoint(x: 31, y: 91)))
    else { return XCTFail("選べる文の層の文") }
    XCTAssertEqual(id, "t")
    XCTAssertEqual(offset, 0)
    try mouse(opened, .leftMouseDown, at: point(CGPoint(x: 31, y: 91)))
    try mouse(opened, .leftMouseUp, at: point(CGPoint(x: 31, y: 91)))
    surface.textView.selectAll(nil)
    let rect = try XCTUnwrap(surface.drawn.zoneSelection?.rects.first)
    XCTAssertEqual(rect.minX, 30, accuracy: 1e-4, "選択の地は層の原点の分ずれる")
    XCTAssertEqual(
      rect.minY, 94 - CTFontGetAscent(ThreadZone.bodyFont), accuracy: 1e-4, "行の帯の上端から")
  }

  /// 配列の中身の置き場所（同じなら、写し直さずに使い回した材料）。
  static func storage<Element>(_ array: [Element]) -> UInt? {
    array.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } }
  }

  /// 頭の層——帯の箱・字の行・押せる場所（描き直しのたびに作る）。
  static func headLayer() -> ZoneLayer {
    ZoneLayer(elements: [
      .box(ZoneBox(frame: CGRect(x: 0, y: 0, width: 300, height: 26), fill: .systemPurple)),
      .text(
        ZoneTextLine(
          origin: CGPoint(x: 12, y: 17), runs: [ZoneTextRun("行 3", font: body, color: .labelColor)])
      ),
      .button(ZoneButton(id: "head", frame: CGRect(x: 200, y: 4, width: 60, height: 18))),
    ])
  }

  /// 本文の層——地の箱・字の行・押せる場所と、文 `content` を幅 `width` で組んだ選べる文。
  static func bodyLayer(_ content: ZoneStyledText, width: CGFloat) -> ZoneLayer {
    ZoneLayer(
      elements: [
        .box(ZoneBox(frame: CGRect(x: 0, y: 0, width: width, height: 60), fill: .systemGray)),
        .text(
          ZoneTextLine(
            origin: CGPoint(x: 0, y: 12), runs: [ZoneTextRun("•", font: body, color: .labelColor)])),
        .button(ZoneButton(id: "link", frame: CGRect(x: 8, y: 0, width: 40, height: 19))),
      ],
      texts: [ZoneText.laid("body", content, width: width, origin: CGPoint(x: 8, y: 14))])
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

  static let body = NSFont.systemFont(ofSize: 12)
  static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static let big = NSFont.systemFont(ofSize: 15)

  /// 描く材料（箱・字の連なり）と当たりの表（字の行・押せる場所）の、最初の食い違い（無ければ nil）。座標は絵の差し込みの
  /// 座標で比べる。
  static func difference(
    _ material: ZoneMaterial, _ hits: ZoneHits, _ expected: ZoneMaterial, _ expectedHits: ZoneHits
  ) -> String? {
    let boxes = { (material: ZoneMaterial) in
      material.layers.flatMap { placed in
        placed.layer.boxes.map {
          ($0.frame.offsetBy(dx: placed.origin.x, dy: placed.origin.y), $0.fill)
        }
      }
    }
    guard boxes(material).elementsEqual(boxes(expected), by: { $0.0 == $1.0 && $0.1 == $1.1 })
    else {
      return "箱"
    }
    guard material.runs.count == expected.runs.count else {
      return "字の連なりの数 \(material.runs.count) ≠ \(expected.runs.count)"
    }
    for (index, (a, b)) in zip(material.runs, expected.runs).enumerated() {
      guard CFEqual(a.font, b.font), a.glyphs == b.glyphs, a.xs == b.xs, a.ys == b.ys,
        a.origin == b.origin, a.ink == b.ink
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
    guard
      hits.buttons.elementsEqual(
        expectedHits.buttons, by: { $0.id == $1.id && $0.frame == $1.frame })
    else { return "押せる場所" }
    return nil
  }
}

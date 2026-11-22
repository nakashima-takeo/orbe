import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import OrbeEditorEngine

/// 主が本文でない間に本文へ直接届く操作（view へのセレクタ・契約の口・IME の呼び出し）を、入力欄の打鍵・絵の差し込みの
/// 文の選択・Esc・押下と混ぜて流しても、打鍵・削除・undo / redo は主の場にだけ効き、契約の選択の口は主を
/// 本文にし、本文の写し・カーソルが文書と一致し、入力欄の場の文・カーソル・変換中の文字が入力欄の文と一致し、主と
/// 絵の差し込みの文の選択が規則どおり（絵の差し込みの文が主なら選択がまとまりの中にあり、そうでなければ選択は無い。
/// 変換中なのは主の場だけ）で、最後に本文と入力欄の undo を尽くすとそれぞれ元に戻る。壊れると「ある順の操作でだけ」
/// 返信の字がソースへ入る・undo が別の場を戻す・変換中の字が場からずれる。
///
/// 2 つの段で確かめる。小さい段（名前の末尾に `AtFullScale` が付かないメソッド）は先頭の種で 400 手、全部の段
/// （付くメソッド）は種の並びの全部で 2,000 手ずつ流す。全部の段は、小さい段と同じ種で始まり、小さい段の 400 手を先頭に
/// 持つ。main では両方のメソッドが走る。
extension SurfaceZonesTests {
  private static let fuzzSeeds: [UInt64] = [0x20e, 0x3, 0x11]

  func testRandomOperationsAcrossTheBodyFieldsAndZoneTextStayConsistent() throws {
    try fuzz(seeds: Self.fuzzSeeds.prefix(1), steps: 400)
  }

  func testRandomOperationsAcrossTheBodyFieldsAndZoneTextStayConsistentAtFullScale() throws {
    try Fuzz.skipFullScaleIfExcluded()
    try fuzz(seeds: Self.fuzzSeeds, steps: 2000)
  }

  /// 種ごとに `steps` 手を流す。最初に失敗した手で止める。
  private func fuzz(seeds: some Sequence<UInt64>, steps: Int) throws {
    for seed in seeds {
      guard try fuzz(seed: seed, steps: steps) else { return }
    }
  }

  private func fuzz(seed: UInt64, steps: Int) throws -> Bool {
    let original = rows(12)
    let opened = try open(original, size: CGSize(width: 600, height: 400), waitForColors: false)
    opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    let window = host(opened, size: CGSize(width: 600, height: 400))
    defer { window.contentView = nil }
    let surface = opened.surface
    let view = surface.textView
    privatePasteboard(opened)
    let field = ZoneTextField(id: "reply", style: ThreadZone.fieldStyle())
    let thread = ThreadZone(comment: "絵の差し込みの選べる文。折り返す長さの文で、二行目へ続く。", field: field)
    thread.surface = surface
    surface.setRows(zone(thread, at: 3))
    var generator = SplitMix(seed: seed)
    // 種の並びの定義と同じ 16 進数で出す。
    let hexSeed = "0x" + String(seed, radix: 16)
    for index in 0..<steps {
      let label = "seed \(hexSeed) step \(index)"
      let passed = Fuzz.step(self, label) {
        let kind = Int.random(in: 0..<22, using: &generator)
        let before = (primary: surface.primary, body: text(opened.document), reply: field.string)
        try step(kind, on: opened, thread, &generator)
        try check(opened, field, label)
        switch kind {
        case 4...8:
          // 打鍵・削除・undo / redo は主の場にだけ効く。
          if before.primary != .body {
            XCTAssertEqual(text(opened.document), before.body, "\(label): 主でない本文は変わらない")
          }
          if before.primary != .field("reply") {
            XCTAssertEqual(field.string, before.reply, "\(label): 主でない入力欄は変わらない")
          }
        case 9:
          XCTAssertEqual(surface.primary, .body, "\(label): 契約の選択の口は主を本文にする")
        default: break
        }
      }
      guard passed else { return false }
    }
    return Fuzz.step(self, "seed \(hexSeed)") {
      surface.setPrimary(.body)
      let body = try XCTUnwrap(view.undoManager)
      while body.canUndo { body.undo() }
      XCTAssertEqual(text(opened.document), original, "seed \(hexSeed): 本文の undo を尽くすと元の本文")
      let site = try XCTUnwrap(surface.fields["reply"])
      while site.editor.undoManager.canUndo { site.editor.undoManager.undo() }
      XCTAssertEqual(field.string, "", "seed \(hexSeed): 入力欄の undo を尽くすと空")
    }
  }

  /// 操作 1 手（`kind` は 0..<22）。
  private func step(
    _ kind: Int, on opened: Opened, _ thread: ThreadZone, _ generator: inout SplitMix
  ) throws {
    let surface = opened.surface
    let view = surface.textView
    guard let field = thread.field, let window = view.window else { return }
    let hits = { surface.zones[ObjectIdentifier(thread)]?.hits ?? ZoneHits() }
    switch kind {
    case 0:
      try click(opened, row: Int.random(in: 0...2, using: &generator), column: 3)
    case 1:
      guard let frame = hits().fields.first?.frame else { break }
      let at = viewPoint(surface, thread, CGPoint(x: frame.minX + 3, y: frame.midY))
      try mouse(opened, .leftMouseDown, at: at)
      try mouse(opened, .leftMouseUp, at: at)
    case 2:
      guard let line = hits().lines.randomElement(using: &generator) else { break }
      let from = viewPoint(surface, thread, CGPoint(x: line.origin.x + 2, y: line.origin.y - 3))
      let to = viewPoint(
        surface, thread, CGPoint(x: line.origin.x + 40, y: line.origin.y - 3))
      try mouse(opened, .leftMouseDown, at: from)
      try mouse(opened, .leftMouseDragged, at: to)
      try mouse(opened, .leftMouseUp, at: to)
    case 3: view.cancelOperation(nil)
    case 4, 5: view.insertText(["a", "日本", "\n", "é"].randomElement(using: &generator)!)
    case 6: view.deleteBackward(nil)
    case 7: view.undo(nil)
    case 8: view.redo(nil)
    case 9:
      let length = opened.document.text.length
      surface.selectedRange = NSRange(
        location: Int.random(in: 0...length, using: &generator), length: 0)
    case 10: surface.reveal(NSRange(location: 0, length: 0), policy: .center)
    case 11:
      surface.replaceAll(with: rows(Int.random(in: 6...12, using: &generator)))
    case 12: surface.setHighlights([NSRange(location: 0, length: 1)], for: .findMatch)
    case 13:
      view.setMarkedText(
        "かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: IMECall.notFound)
    case 14: view.insertText("仮名", replacementRange: IMECall.notFound)
    case 15: view.unmarkText()
    case 16: view.copy(nil)
    case 17: view.selectAll(nil)
    case 18: surface.commitMarkedText()
    case 19: surface.replaceText(of: field, with: "")
    case 20: surface.focus(field)
    default:
      window.makeFirstResponder(nil)
      window.makeFirstResponder(view)
    }
  }

  private func check(_ opened: Opened, _ field: ZoneTextField, _ step: String) throws {
    let surface = opened.surface
    let content = try XCTUnwrap(surface.drawn.content)
    XCTAssertEqual(content.version, opened.document.version, "\(step): 面の写しは文書と同じ版")
    let length = opened.document.text.length
    for cursor in surface.editor.state.cursors.all {
      XCTAssertLessThanOrEqual(NSMaxRange(cursor.selection), length, "\(step)")
    }
    let site = try XCTUnwrap(surface.fields["reply"], "\(step): 入力欄の場は、絵にその入力欄がある限り続く")
    XCTAssertEqual(site.currentContent?.text.length, field.text.length, "\(step)")
    for cursor in site.editor.state.cursors.all {
      XCTAssertLessThanOrEqual(NSMaxRange(cursor.selection), field.text.length, "\(step)")
    }
    if let composition = site.editor.composition {
      XCTAssertLessThanOrEqual(NSMaxRange(composition.range), field.text.length, "\(step)")
    }
    switch surface.primary {
    case .zoneText:
      let selection = try XCTUnwrap(surface.zoneSelection, "\(step): 絵の差し込みの文が主なら選択がある")
      let rope = surface.zones[selection.zone]?.hits.rope(of: selection.text)
      XCTAssertLessThanOrEqual(NSMaxRange(selection.range), rope?.length ?? -1, "\(step)")
    case .body, .field:
      XCTAssertNil(surface.zoneSelection, "\(step): 絵の差し込みの文が主でなければ選択は無い")
    }
    let composing = [surface.bodySite, site].filter { $0.editor.isComposing }
    XCTAssertTrue(
      composing.allSatisfy { $0 === surface.primarySite }, "\(step): 変換中なのは主の場だけ")
  }
}

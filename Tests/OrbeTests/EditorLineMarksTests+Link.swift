import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// URL の ⌘クリック。
extension EditorLineMarksTests {

  /// マウスの合成イベント（窓座標）。
  private func mouse(
    _ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags, in window: NSWindow
  ) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1))
  }

  /// ⌘クリックだけが URL を渡し、素のクリックはキャレットを置く。URL の外の ⌘クリックは上流に落ちる。
  /// ⌘に他の修飾が重なれば上流の選択操作（⌘⇧＝選択の延長）に渡す。
  func testCommandClickOpensTheLinkAndPlainClickPlacesTheCaret() throws {
    let hosted = try host("see https://a.b/c\n")
    let document = hosted.document
    let window = hosted.window
    var opened: [URL] = []
    document.surface.onOpenLink = { opened.append($0) }
    let client = try XCTUnwrap(document.surface.responder as? NSTextInputClient)
    let onURL = document.surface.responder.convert(
      NSPoint(x: 8 * cell, y: rowMidY(1) - style.topInset), to: nil)
    let offURL = document.surface.responder.convert(
      NSPoint(x: 1 * cell, y: rowMidY(1) - style.topInset), to: nil)
    func click(_ point: NSPoint, _ flags: NSEvent.ModifierFlags) throws {
      document.surface.responder.mouseDown(
        with: try mouse(.leftMouseDown, point, flags, in: window))
      document.surface.responder.mouseUp(with: try mouse(.leftMouseUp, point, flags, in: window))
    }

    try click(onURL, [.command])
    XCTAssertEqual(opened.map(\.absoluteString), ["https://a.b/c"])

    try click(onURL, [])
    XCTAssertEqual(opened.count, 1, "素のクリックは開かない")
    XCTAssertTrue(
      (7...9).contains(client.selectedRange().location), "キャレットが置かれる: \(client.selectedRange())")

    try click(offURL, [.command])
    XCTAssertEqual(opened.count, 1, "URL の外の ⌘クリックは開かない")
    XCTAssertTrue((0...2).contains(client.selectedRange().location), "上流へ落ちてキャレットが動く")

    try click(onURL, [.command, .shift])
    XCTAssertEqual(opened.count, 1, "⌘⇧は上流の選択の延長")
    XCTAssertGreaterThan(client.selectedRange().length, 0, "キャレットから URL の上まで選択が延びる")
  }

  /// 開くのは離したとき——押した URL の上で離せば開き、押したまま動かして離せば開かず（動きが小さくても
  /// URL の外で離せば開かない）、その間は選択も伸びない。
  func testCommandClickOpensOnMouseUpAndDraggingCancels() throws {
    let hosted = try host("see https://a.b/c\n")
    let document = hosted.document
    let window = hosted.window
    var opened: [URL] = []
    document.surface.onOpenLink = { opened.append($0) }
    let client = try XCTUnwrap(document.surface.responder as? NSTextInputClient)
    let responder = document.surface.responder
    let onURL = responder.convert(
      NSPoint(x: 8 * cell, y: rowMidY(1) - style.topInset), to: nil)
    let before = client.selectedRange()

    responder.mouseDown(with: try mouse(.leftMouseDown, onURL, [.command], in: window))
    XCTAssertEqual(opened, [], "押しただけでは開かない")
    responder.mouseUp(with: try mouse(.leftMouseUp, onURL, [.command], in: window))
    XCTAssertEqual(opened.map(\.absoluteString), ["https://a.b/c"], "離して開く")

    responder.mouseDown(with: try mouse(.leftMouseDown, onURL, [.command], in: window))
    let away = NSPoint(x: onURL.x - 6 * cell, y: onURL.y)  // "see " の上（URL の外）
    responder.mouseDragged(with: try mouse(.leftMouseDragged, away, [.command], in: window))
    responder.mouseUp(with: try mouse(.leftMouseUp, away, [.command], in: window))
    XCTAssertEqual(opened.count, 1, "ドラッグして外れれば開かない")
    XCTAssertEqual(client.selectedRange(), before, "その間に選択は伸びない")

    let edge = responder.convert(
      NSPoint(x: 16.8 * cell, y: rowMidY(1) - style.topInset), to: nil)
    responder.mouseDown(with: try mouse(.leftMouseDown, edge, [.command], in: window))
    let justOutside = NSPoint(x: edge.x + 2, y: edge.y)
    responder.mouseUp(with: try mouse(.leftMouseUp, justOutside, [.command], in: window))
    XCTAssertEqual(opened.count, 1, "動きが 2pt でも URL の外で離せば開かない")
  }
}

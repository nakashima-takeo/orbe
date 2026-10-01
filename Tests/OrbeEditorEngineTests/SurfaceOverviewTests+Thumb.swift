import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 面の縦横のつまみとミニマップの帯の見え隠れ（VS Code と同じ規則）。壊れると窓の大きさ・改行・横スクロールでつまみが
/// 現れない、行の中の打鍵のたびにつまみが現れる、横に続く本文があるのに横のつまみが無い（無いのに出る）、つまみや帯を
/// 掴んで外で離しても残る、帯を掴んで外へ出た途端に消える。
@MainActor
final class SurfaceThumbTests: EngineTestCase {
  /// 縦のつまみの上端近くの画素（キャレットの印より下）。
  private func verticalThumb(_ opened: Opened) throws -> [Int] {
    try pixelShot(opened).rgb(opened.surface.surfaceLayout.verticalScrollbar.midX, 10)
  }

  /// つまみはスクロールの状態が変わると現れる——縦の位置に限らず、面の高さと幅・改行（行数）・横スクロールでも。行の中の
  /// 打鍵では出ない。
  func testTheThumbShowsWhenTheScrollStateChanges() throws {
    let opened = try hosted(String(repeating: "x", count: 400) + "\n" + rows(1000))
    let surface = opened.surface
    XCTAssertEqual(try verticalThumb(opened), [0, 0, 0], "前提: 開いた直後は隠れる")
    let rope = opened.document.text
    surface.selectedRange = NSRange(location: rope.lineStart(3), length: 0)
    let shows = { (label: String, change: () -> Void) throws in
      change()
      XCTAssertNotEqual(try self.verticalThumb(opened), [0, 0, 0], "\(label) で現れる")
      self.pump(until: { (try? self.verticalThumb(opened)) == [0, 0, 0] }, "\(label) の後、止まれば消える")
    }
    try shows("面の高さ") {
      surface.viewStateDidChange(size: CGSize(width: 800, height: 300), scale: 2, visible: false)
    }
    try shows("面の幅") {
      surface.viewStateDidChange(size: CGSize(width: 700, height: 300), scale: 2, visible: false)
    }
    try shows("改行") { surface.responder.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    type(opened, "a")
    XCTAssertEqual(try verticalThumb(opened), [0, 0, 0], "行の中の打鍵では出ない")
    try shows("横スクロール") { surface.scroll(toX: 200) }
  }

  /// つまみを押したまま本体の外へ出ても、ドラッグ中は見え続け（止まって 500ms を過ぎても）、外で離せばドラッグで動いた
  /// 直後でもすぐ消える。
  func testReleasingADragOutsideTheBodyHidesTheThumb() throws {
    let opened = try hosted(rows(2000))
    let view = opened.surface.textView
    let bar = opened.surface.surfaceLayout.verticalScrollbar
    let grab = CGPoint(x: bar.midX, y: 10)
    let outside = CGPoint(x: -50, y: 60)
    let crossing = { (type: NSEvent.EventType, point: CGPoint) throws -> NSEvent in
      try XCTUnwrap(
        NSEvent.enterExitEvent(
          with: type, location: view.convert(point, to: nil), modifierFlags: [],
          timestamp: CACurrentMediaTime(), windowNumber: view.window?.windowNumber ?? 0,
          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }
    let shown = { () throws -> Bool in
      let shot = try self.pixelShot(opened)
      return stride(from: CGFloat(5), to: bar.maxY, by: 2).contains { shot.hasInk(bar.midX, $0) }
    }
    view.mouseEntered(with: try crossing(.mouseEntered, grab))
    try mouse(opened, .leftMouseDown, at: grab)
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: grab.x, y: 60))
    XCTAssertGreaterThan(opened.surface.viewportLines.first, 0, "前提: ドラッグで動いた")
    XCTAssertTrue(try shown())
    view.mouseExited(with: try crossing(.mouseExited, outside))
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    XCTAssertTrue(try shown(), "ドラッグ中は外でも、止まって 500ms を過ぎても見える")
    try mouse(opened, .leftMouseDragged, at: CGPoint(x: outside.x, y: 80))
    XCTAssertTrue(try shown())
    try mouse(opened, .leftMouseUp, at: CGPoint(x: outside.x, y: 80))
    XCTAssertFalse(try shown(), "外で離せば、動いた直後でもすぐ消える")
  }

  /// ミニマップの帯を押したまま外へ出ても、ドラッグ中は見え続け、外で離せば消える。
  func testReleasingASliderDragOutsideTheMinimapHidesTheSlider() throws {
    let opened = try hosted(rows(2000))
    let view = opened.surface.textView
    let minimap = opened.surface.surfaceLayout.minimap
    let placement = try XCTUnwrap(opened.surface.placementBox.read())
    let grab = CGPoint(x: minimap.maxX - 4, y: placement.sliderTop + placement.sliderHeight / 2)
    let outside = CGPoint(x: -50, y: grab.y)
    let crossing = { (type: NSEvent.EventType, point: CGPoint) throws -> NSEvent in
      try XCTUnwrap(
        NSEvent.enterExitEvent(
          with: type, location: view.convert(point, to: nil), modifierFlags: [],
          timestamp: CACurrentMediaTime(), windowNumber: view.window?.windowNumber ?? 0,
          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }
    let shown = { () throws -> Bool in
      let shot = try self.pixelShot(opened)
      let slider = try XCTUnwrap(opened.surface.placementBox.read())
      return shot.hasInk(minimap.maxX - 2, slider.sliderTop + 1)
    }
    XCTAssertFalse(try shown(), "前提: 普段は隠れる")
    view.mouseEntered(with: try crossing(.mouseEntered, grab))
    opened.surface.inputScope { view.overview.pointerMoved(to: grab, inside: true) }
    try mouse(opened, .leftMouseDown, at: grab)
    XCTAssertTrue(try shown(), "掴むと見える")
    view.mouseExited(with: try crossing(.mouseExited, outside))
    try mouse(opened, .leftMouseDragged, at: outside)
    XCTAssertTrue(try shown(), "ドラッグ中は外でも見える")
    try mouse(opened, .leftMouseUp, at: outside)
    XCTAssertFalse(try shown(), "外で離せば消える")
  }

  /// 横に続く本文があるときだけ、本文の区画の下端に横のつまみが出て、その位置が横の位置を表す。
  func testTheHorizontalThumbShowsOnlyWhileTheTextContinuesSideways() throws {
    let opened = try hosted(rows(10, width: 400))
    let bar = opened.surface.surfaceLayout.horizontalScrollbar
    let hover = { (opened: Opened) in
      opened.surface.inputScope {
        opened.surface.textView.overview.pointerMoved(to: CGPoint(x: 300, y: 100), inside: true)
      }
    }
    hover(opened)
    let start = try pixelShot(opened)
    XCTAssertNotEqual(start.rgb(bar.minX + 5, bar.midY), [0, 0, 0], "左端にいれば左端に出る")
    XCTAssertEqual(start.rgb(bar.maxX - 5, bar.midY), [0, 0, 0])
    opened.surface.scroll(toX: opened.surface.scrollState().limits.maximum.x)
    let end = try pixelShot(opened)
    XCTAssertEqual(end.rgb(bar.minX + 5, bar.midY), [0, 0, 0])
    XCTAssertNotEqual(end.rgb(bar.maxX - 5, bar.midY), [0, 0, 0], "右端まで送れば右端に出る")

    let narrow = try hosted(rows(10))
    hover(narrow)
    let shot = try pixelShot(narrow)
    for x in stride(from: bar.minX + 2, to: bar.maxX, by: 20) {
      XCTAssertEqual(shot.rgb(x, bar.midY), [0, 0, 0], "横に続かなければ無い（x \(x)）")
    }
  }
}

import AppKit
import XCTest

@testable import OrbeEditorEngine

/// 窓に載せた面の入口へ、AppKit が送るのと同じ phase つきのスクロールの出来事（CGEvent から作った NSEvent）を流し、端への
/// 戻りの途中に新しい指の動き・ホイールがその場で効くことを固定する。壊れると、端で弾んで戻っている間は指で動かしても
/// 本文が付いてこない。
@MainActor
final class SurfaceScrollWheelTests: EngineTestCase {
  private enum Phase: Int64 {
    case none = 0, began = 1, changed = 2, ended = 4, mayBegin = 128
  }

  /// トラックパッドの出来事（画素単位・phase つき）。`dy` は正で本文が下へ動く向き。
  private func finger(_ opened: Opened, _ dy: Int32, _ phase: Phase) throws {
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0,
        wheel3: 0))
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    try send(opened, event)
  }

  /// マウスのホイール（行単位・phase なし）。
  private func wheel(_ opened: Opened, lines: Int32) throws {
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
        wheel3: 0))
    try send(opened, event)
  }

  private func send(_ opened: Opened, _ event: CGEvent) throws {
    // NSEvent の時刻（起動からの秒）は CACurrentMediaTime と同じ時計。
    event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    opened.surface.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
  }

  /// 先頭で下へ引いて端の外へ伸ばし、指を離す（端へ戻り始める）。
  private func pullPastTopAndRelease(_ opened: Opened) throws {
    try finger(opened, 0, .mayBegin)
    try finger(opened, 0, .began)
    for _ in 0..<20 { try finger(opened, 40, .changed) }
    try finger(opened, 0, .ended)
    XCTAssertLessThan(opened.surface.scrollPosition.y, -20, "前提: 上端の外へ伸びている")
    pump { false }
  }

  private func pump(for seconds: TimeInterval = 0.04, _ until: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !until(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
  }

  func testNewFingerGestureDuringReturnMovesAtOnce() throws {
    let opened = try hosted(rows(200))
    try pullPastTopAndRelease(opened)
    try finger(opened, 0, .mayBegin)
    try finger(opened, 0, .began)
    let from = opened.surface.scrollPosition.y
    XCTAssertLessThan(from, 0, "前提: 戻りの途中で止めた")
    for _ in 0..<10 { try finger(opened, -30, .changed) }
    XCTAssertEqual(opened.surface.scrollPosition.y, from + 300, accuracy: 1, "指の量がその場で入る")
    pump(for: 0.3) { false }
    XCTAssertEqual(
      opened.surface.scrollPosition.y, from + 300, accuracy: 1, "指を置いている間は戻りの式で上書きされない")
    try finger(opened, 0, .ended)
    pump(for: 0.3) { false }
    XCTAssertEqual(opened.surface.scrollPosition.y, from + 300, accuracy: 1, "端の内側で離せば止まる")
  }

  func testWheelDuringReturnMovesAtOnce() throws {
    let opened = try hosted(rows(200))
    try pullPastTopAndRelease(opened)
    let from = opened.surface.scrollPosition.y
    XCTAssertLessThan(from, 0, "前提: 戻りの途中")
    try wheel(opened, lines: -10)
    // 読んでから出来事の時刻までに戻りが進む分（1ms 未満で 1pt 未満）を許す。
    let moved = opened.surface.scrollPosition.y
    XCTAssertEqual(moved, from + 100, accuracy: 2, "その時点の位置から 10 行分入る")
    pump(for: 0.3) { false }
    XCTAssertEqual(opened.surface.scrollPosition.y, moved, "戻りは打ち切られている")
  }
}

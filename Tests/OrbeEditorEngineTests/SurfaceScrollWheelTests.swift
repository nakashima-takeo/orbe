import AppKit
import OrbeTestSupport
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

  /// 出来事の時刻と、位置を読む時刻（`CACurrentMediaTime` の時計）。テストが進める（戻さない）。面は窓に載せるが、窓を
  /// 画面に出さないので面は見えておらず、描画スレッドはコマを組まない。スクロールの物理の状態を実時間で進めるのはコマを
  /// 組むときだけなので、位置は出来事と読む時刻だけで決まる。
  private var now = 0.0

  override func setUpWithError() throws {
    try super.setUpWithError()
    now = CACurrentMediaTime()
  }

  /// トラックパッドの出来事（画素単位・phase つき）。`dy` は正で本文が下へ動く向き。
  private func finger(_ opened: Opened, _ dy: Int32, _ phase: Phase) throws {
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: SyntheticInput.source, units: .pixel, wheelCount: 1, wheel1: dy,
        wheel2: 0,
        wheel3: 0))
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    try send(opened, event)
  }

  /// マウスのホイール（行単位・phase なし）。
  private func wheel(_ opened: Opened, lines: Int32) throws {
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: SyntheticInput.source, units: .line, wheelCount: 1, wheel1: lines,
        wheel2: 0,
        wheel3: 0))
    try send(opened, event)
  }

  private func send(_ opened: Opened, _ event: CGEvent) throws {
    // NSEvent の時刻（起動からの秒）は CACurrentMediaTime と同じ時計。CGEvent の時刻はその ns。
    event.timestamp = CGEventTimestamp(now * 1e9)
    opened.surface.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
  }

  /// テストの時刻から `ahead` 秒先に見せる縦の位置。
  private func position(_ opened: Opened, ahead: Double = 0) -> Double {
    opened.surface.scrollState(at: now + ahead).position.y
  }

  /// 先頭で下へ引いて端の外へ伸ばし、指を離す（端へ戻り始める）。
  private func pullPastTopAndRelease(_ opened: Opened) throws {
    try finger(opened, 0, .mayBegin)
    try finger(opened, 0, .began)
    for _ in 0..<20 { try finger(opened, 40, .changed) }
    try finger(opened, 0, .ended)
    let released = position(opened)
    XCTAssertLessThan(released, -20, "前提: 上端の外へ伸びている")
    XCTAssertGreaterThan(
      position(opened, ahead: 0.3), released / 10,
      "触らなければ、0.3 秒先の位置は端へ戻っている。testNewFingerGestureDuringReturnMovesAtOnce の"
        + "「指を置いている間は戻りの式で上書きされない」「端の内側で離せば止まる」と、testWheelDuringReturnMovesAtOnce の"
        + "「戻りは打ち切られている」の対で、これが待たずに成り立たなくなったら、それらのテストが確かめる時点も成り立たない")
    now += 0.04
  }

  func testNewFingerGestureDuringReturnMovesAtOnce() throws {
    let opened = try hosted(rows(200))
    try pullPastTopAndRelease(opened)
    try finger(opened, 0, .mayBegin)
    try finger(opened, 0, .began)
    let from = position(opened)
    XCTAssertLessThan(from, 0, "前提: 戻りの途中で止めた")
    for _ in 0..<10 { try finger(opened, -30, .changed) }
    XCTAssertEqual(position(opened), from + 300, accuracy: 1, "指の量がその場で入る")
    now += 0.3
    XCTAssertEqual(position(opened), from + 300, accuracy: 1, "指を置いている間は戻りの式で上書きされない")
    try finger(opened, 0, .ended)
    now += 0.3
    XCTAssertEqual(position(opened), from + 300, accuracy: 1, "端の内側で離せば止まる")
  }

  func testWheelDuringReturnMovesAtOnce() throws {
    let opened = try hosted(rows(200))
    try pullPastTopAndRelease(opened)
    let from = position(opened)
    XCTAssertLessThan(from, 0, "前提: 戻りの途中")
    try wheel(opened, lines: -10)
    let moved = position(opened)
    // 出来事の時刻は ns に丸めて持つので、読む時刻との差で戻りが進む分（10⁻⁶ pt 未満）を許す。
    XCTAssertEqual(moved, from + 100, accuracy: 1e-6, "その時点の位置から 10 行分入る")
    now += 0.3
    XCTAssertEqual(position(opened), moved, "戻りは打ち切られている")
  }
}

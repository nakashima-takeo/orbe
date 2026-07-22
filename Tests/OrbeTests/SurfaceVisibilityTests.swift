import XCTest

@testable import Orbe

/// `SurfaceOcclusionGate` の可視性導出と差分ゲートの検証。
/// libghostty の可視性契約（不可視で描画停止・可視復帰で 1 フレーム保証）へ送る合成値
/// 「inWindow AND !hiddenAncestor AND windowVisible」と、同値スキップ・初回必送の
/// ゲート規律を C API 呼び出しから分離して検証する。
final class SurfaceVisibilityTests: XCTestCase {
  // MARK: - 可視性の導出（合成）

  /// 全条件成立でのみ可視。
  func testDeriveVisibleWhenAllConditionsMet() {
    XCTAssertTrue(
      SurfaceOcclusionGate.derive(
        inWindow: true, hiddenOrHasHiddenAncestor: false, windowVisible: true))
  }

  /// window 未接続（WS 切替のデタッチ中）は不可視。
  func testDeriveHiddenWhenDetached() {
    XCTAssertFalse(
      SurfaceOcclusionGate.derive(
        inWindow: false, hiddenOrHasHiddenAncestor: false, windowVisible: true))
  }

  /// 自分/祖先の isHidden（タブ切替の隠れタブ）は不可視。
  func testDeriveHiddenWhenAncestorHidden() {
    XCTAssertFalse(
      SurfaceOcclusionGate.derive(
        inWindow: true, hiddenOrHasHiddenAncestor: true, windowVisible: true))
  }

  /// ウィンドウ occluded（最小化・別 Space）は不可視。
  func testDeriveHiddenWhenWindowOccluded() {
    XCTAssertFalse(
      SurfaceOcclusionGate.derive(
        inWindow: true, hiddenOrHasHiddenAncestor: false, windowVisible: false))
  }

  /// 複合不成立でも不可視（合成は AND）。
  func testDeriveHiddenWhenMultipleConditionsFail() {
    XCTAssertFalse(
      SurfaceOcclusionGate.derive(
        inWindow: false, hiddenOrHasHiddenAncestor: true, windowVisible: false))
  }

  // MARK: - 差分ゲート

  /// 初回は値に依らず必ず送る（renderer の visible 初期値 true との不整合を防ぐ。
  /// 特に隠れ状態で生まれる遅延 mount の surface に false を確実に届ける）。
  func testFirstSendAlwaysFires() {
    var visibleFirst = SurfaceOcclusionGate()
    XCTAssertTrue(visibleFirst.shouldSend(true))

    var hiddenFirst = SurfaceOcclusionGate()
    XCTAssertTrue(hiddenFirst.shouldSend(false))
  }

  /// 同値の再送はスキップする（冪等。再アタッチ等の重複コールバックで無駄撃ちしない）。
  func testSameValueIsSkipped() {
    var gate = SurfaceOcclusionGate()
    XCTAssertTrue(gate.shouldSend(true))
    XCTAssertFalse(gate.shouldSend(true))
    XCTAssertFalse(gate.shouldSend(true))
  }

  /// 値が転じるたびに送る（タブ切替往復・WS 切替の false→true 往復）。
  func testToggleSendsEachTransition() {
    var gate = SurfaceOcclusionGate()
    XCTAssertTrue(gate.shouldSend(false))
    XCTAssertTrue(gate.shouldSend(true))
    XCTAssertTrue(gate.shouldSend(false))
    XCTAssertTrue(gate.shouldSend(true))
  }

  /// 送信済みの値を lastSent として保持する（送信スキップ時は据え置き）。
  func testLastSentTracksCommittedValue() {
    var gate = SurfaceOcclusionGate()
    XCTAssertNil(gate.lastSent)
    _ = gate.shouldSend(true)
    XCTAssertEqual(gate.lastSent, true)
    _ = gate.shouldSend(true)
    XCTAssertEqual(gate.lastSent, true)
    _ = gate.shouldSend(false)
    XCTAssertEqual(gate.lastSent, false)
  }
}

import XCTest

@testable import Orbe

/// `SurfaceOcclusionGate` の差分ゲートの検証。libghostty の可視性契約（不可視で描画停止・可視復帰で 1 フレーム保証）へ
/// 送る値を、初回は必ず送り、同値は飛ばし、転じるたびに送る。
final class SurfaceVisibilityTests: OrbeTestCase {
  /// 初回は値に依らず必ず送る（renderer の visible 初期値 true との不整合を防ぐ。
  /// 特に隠れ状態で生まれる遅延 mount の surface に false を確実に届ける）。
  func testFirstSendAlwaysFires() {
    var visibleFirst = SurfaceOcclusionGate()
    XCTAssertTrue(visibleFirst.shouldSend(true))

    var hiddenFirst = SurfaceOcclusionGate()
    XCTAssertTrue(hiddenFirst.shouldSend(false))
  }

  /// 同値の再送は飛ばし（再アタッチ等の重複コールバックで無駄撃ちしない）、値が転じるたびに送る（タブ切替・WS 切替の往復）。
  func testSendsOnlyWhenTheValueTurns() {
    var gate = SurfaceOcclusionGate()
    XCTAssertTrue(gate.shouldSend(true))
    XCTAssertFalse(gate.shouldSend(true))
    XCTAssertTrue(gate.shouldSend(false))
    XCTAssertFalse(gate.shouldSend(false))
    XCTAssertTrue(gate.shouldSend(true))
  }
}

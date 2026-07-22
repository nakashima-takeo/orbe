import AppKit
import XCTest

@testable import Orbe

/// 状態→グリフ種別のマッピング検証。AppKit のみ・libghostty 非依存。
final class AgentStateIconTests: XCTestCase {
  func testKindNilForNilState() {
    XCTAssertNil(AgentStateIcon.kind(state: nil), "状態なしはグリフ無し")
  }

  func testKindNilForUndefinedState() {
    XCTAssertNil(AgentStateIcon.kind(state: "error"), "種別未定義の状態はグリフ無し")
  }

  func testIdleHasKindForRollup() {
    // idle はタブには出ない（aggregateAgentState が除外）が、横断ロールアップには出すため
    // 種別自体は持つ。タブ非表示の担保は TerminalControllerTests 側。
    XCTAssertEqual(AgentStateIcon.kind(state: "idle"), .idle, "idle は横断ロールアップ用の種別を持つ")
  }

  func testDormantHasKindForIconList() {
    // dormant kind は設定パレットのアイコン候補一覧（状態一覧）に出る。状態→種別の解決保証。
    XCTAssertEqual(AgentStateIcon.kind(state: "dormant"), .dormant, "休眠は状態→種別を解決できる")
  }

  func testKnownStatesResolveToDistinctTabKinds() {
    XCTAssertEqual(AgentStateIcon.kind(state: "working"), .working)
    XCTAssertEqual(AgentStateIcon.kind(state: "waiting"), .waiting)
    XCTAssertEqual(AgentStateIcon.kind(state: "done"), .done)
  }
}

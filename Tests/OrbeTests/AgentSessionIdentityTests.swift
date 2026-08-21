import XCTest

@testable import Orbe

/// 報告による同一性の更新（`AgentSession.updated`）。sessionId の sticky が **同じ CLI からの
/// 報告のあいだだけ** に閉じることを固定する——session id は発行した CLI に属する値なので、
/// 「command は codex・sessionId は claude 由来」という resume 不能なペアは作らせない。
final class AgentSessionIdentityTests: OrbeTestCase {

  /// 同じ CLI からの報告では、sessionId は新値があれば更新・無ければ維持。
  func testSessionIdStickyWithinSameCommand() {
    let session = AgentSession(command: "claude", sessionId: "a")
    XCTAssertEqual(
      session.updated(command: "claude", sessionId: nil),
      AgentSession(command: "claude", sessionId: "a"), "新値なしなら維持")
    XCTAssertEqual(
      session.updated(command: "claude", sessionId: "b"),
      AgentSession(command: "claude", sessionId: "b"), "新値があれば更新")
  }

  /// CLI が入れ替わったら、新値が無い限り旧 sessionId は捨てる。
  func testSessionIdDroppedWhenCommandChanges() {
    let session = AgentSession(command: "claude", sessionId: "a")
    XCTAssertEqual(
      session.updated(command: "codex", sessionId: nil),
      AgentSession(command: "codex", sessionId: nil), "他 CLI の id は resume 不能なので捨てる")
    XCTAssertEqual(
      session.updated(command: "codex", sessionId: "c1"),
      AgentSession(command: "codex", sessionId: "c1"), "新 CLI 自身の id は載る")
  }
}

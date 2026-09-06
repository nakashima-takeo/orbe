import Foundation
import OrbeSessionLog
import XCTest

@testable import Orbe

/// `session_log` / `restore_sessions` の wire 契約。
///
/// 壊れると何が起きるか: `session_log` が params を黙って無視すれば `orb session log --since` が全件を
/// 返し、窓を要するようになれば Orbe が起きた直後の `orb session closed` が "no window" で落ちる。
/// `restore_sessions` の安全文字集合が緩めば、ログに載った id が resume コマンドへそのまま埋まる。
extension ControlWireTests {
  private func event(_ id: String, at seconds: TimeInterval, closed: Bool) -> SessionEvent {
    SessionEvent(
      ts: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
      kind: closed ? .closed(origin: .process, reason: nil, title: nil) : .opened,
      workspace: .init(name: "w", rootPath: "/tmp"), cwd: "/tmp",
      agent: .init(command: "claude", sessionId: id))
  }

  private func events(_ response: [String: Any]?) -> [[String: Any]]? {
    (response?["result"] as? [String: Any])?["events"] as? [[String: Any]]
  }

  /// ファイル不在は `events: []` の成功（エラーではない）。target 無しでも答える。
  func testSessionLogWithoutFileOrWindowIsEmptySuccess() {
    let wire = startWireWithoutTarget()
    let response = wire.request(id: 1, method: "session_log")
    XCTAssertNil(response?["error"], "窓を要さない")
    XCTAssertEqual(events(response)?.count, 0)
    XCTAssertEqual((response?["result"] as? [String: Any])?["truncated"] as? Bool, false)
  }

  /// ファイル順で wire 形（`ts` は文字列のまま）を返し、since / until / sessionId / limit が効く。
  func testSessionLogReturnsFileOrderAndHonoursFilters() throws {
    let url = try XCTUnwrap(AgentSessionLog.fileURL)
    for e in [
      event("a", at: 0, closed: false), event("b", at: 10, closed: false),
      event("a", at: 20, closed: true), event("b", at: 30, closed: true),
    ] {
      try SessionLogWriter.append(e, to: url)
    }
    let wire = startWireWithoutTarget()

    let all = try XCTUnwrap(events(wire.request(id: 1, method: "session_log")))
    XCTAssertEqual(all.count, 4)
    XCTAssertEqual(all[0]["ts"] as? String, "2027-01-15T08:00:00.000Z", "ts は wire の文字列")
    XCTAssertEqual(all[2]["event"] as? String, "closed")
    XCTAssertEqual(all[2]["origin"] as? String, "process")
    XCTAssertNil(all[0]["origin"], "opened に origin は無い")

    let window = wire.request(
      id: 2, method: "session_log",
      params: ["since": "2027-01-15T08:00:10Z", "until": "2027-01-15T08:00:20.000Z"])
    XCTAssertEqual(
      try XCTUnwrap(events(window)).map {
        ($0["agent"] as? [String: Any])?["sessionId"] as? String
      },
      ["b", "a"], "閉区間で絞る（小数秒なしも受理）")

    let only = wire.request(id: 3, method: "session_log", params: ["sessionId": "b"])
    XCTAssertEqual(events(only)?.count, 2)

    let limited = wire.request(id: 4, method: "session_log", params: ["limit": 1])
    XCTAssertEqual(
      (events(limited)?.first?["agent"] as? [String: Any])?["sessionId"] as? String, "b",
      "超過時は新しい側を残す")
    XCTAssertEqual((limited?["result"] as? [String: Any])?["truncated"] as? Bool, true)
  }

  /// 型違い・ISO 不正・limit の値域外・limit の JSON Bool（NSNumber 越しに 1 と読めてしまう）は -32602。
  func testSessionLogRejectsMalformedParams() {
    let wire = startWireWithoutTarget()
    var id = 0
    for params in [
      ["since": 12], ["since": "yesterday"], ["until": ["x"]], ["limit": 0],
      ["limit": SessionLogLimits.maxLimit + 1], ["limit": "10"], ["limit": true],
      ["sessionId": 3],
    ] as [[String: Any]] {
      id += 1
      XCTAssertEqual(
        errorCode(wire.request(id: id, method: "session_log", params: params)), -32602,
        "\(params) は -32602")
    }
  }

  /// 空・上限 +1 件・安全文字集合の外は -32602（target へ届かない）。
  func testRestoreSessionsRejectsBadIdLists() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var id = 0
    for ids in [
      [], Array(repeating: "s", count: SessionLogLimits.restoreMaxIds + 1), ["ok", "a;rm -rf /"],
      [""],
    ] {
      id += 1
      XCTAssertEqual(
        errorCode(wire.request(id: id, method: "restore_sessions", params: ["sessionIds": ids])),
        -32602, "\(ids.count) 件 / \(ids.last ?? "") は -32602")
    }
    XCTAssertEqual(
      errorCode(wire.request(id: 99, method: "restore_sessions", params: ["sessionIds": "s-1"])),
      -32602, "配列でない sessionIds は欠落と同じ")
    XCTAssertTrue(fake.restoredSessionIds.isEmpty, "弾いた要求は target へ届かない")
  }

  /// 正しい列挙はそのまま target へ届き、結果の `results` が返る。窓なしは -32000。
  func testRestoreSessionsReachesTargetAndNeedsAWindow() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "restore_sessions", params: ["sessionIds": ["s-1", "s-2"]])
    XCTAssertEqual(fake.restoredSessionIds, [["s-1", "s-2"]])
    XCTAssertEqual(
      ((response?["result"] as? [String: Any])?["results"] as? [[String: Any]])?.count, 2)

    wire.teardown()
    let noWindow = startWireWithoutTarget()
    XCTAssertEqual(
      errorCode(noWindow.request(id: 2, method: "restore_sessions", params: ["sessionIds": ["s"]])),
      -32000)
  }
}

import XCTest

@testable import Orbe

/// ノードごとの外の口——流している間の一覧の `running` と、道の重なる `run_automation` の断り、`pause_automation` の
/// `nodeKey`（知らない鍵は -32004）と一覧のノードの `paused`・`nextRunAt`。
///
/// 壊れると何が起きるか: 流している自動化への `run_automation` が別の誤りに化け、AI がどのノードの流しを待てばよいか分からない。
/// AI がノードだけを止めたつもりで自動化ごと止まる、または止まらない。一覧で止めたノードを見分けられず、動いていないノードの
/// 次の時刻を読んで待ち続ける。
extension WindowControllerAutomationControlTests {
  /// 流している間は走っているノードが一覧にそう出て、道の重なる `run_automation` は重なったノードを言って断られる。
  func testFlowingAutomationIsListedAsRunningAndRefusesAnotherRun() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition(script: "sleep 30"))
    addTeardownBlock { _ = wc.controlDeleteAutomation(automationId: id) }

    _ = try success(wc.controlRunAutomation(automationId: id, nodeKey: nil))

    let nodes = try XCTUnwrap(try listed(wc)[id]?["nodes"] as? [String: [String: Any]])
    XCTAssertEqual(nodes["fetch"]?["running"] as? Bool, true)
    XCTAssertEqual(nodes["judge"]?["running"] as? Bool, false)
    guard case .failure(let refused) = wc.controlRunAutomation(automationId: id, nodeKey: "fetch")
    else { return XCTFail("道の重なる流しを受けた") }
    XCTAssertTrue(
      refused.code == -32000 && refused.message.contains(#"node "fetch""#), "\(refused)")
  }

  /// `pause_automation` に鍵を添えるとそのノードだけが止まり、一覧ではそのノードに `paused` が立って `nextRunAt` が消える。
  /// 自動化とほかのノードは止まらない。再開すると戻る。知らない鍵は -32004。
  func testPausingANodeIsListedOnThatNodeOnly() throws {
    let wc = try launch()
    let id = try set(wc, Self.definition())
    func nodes() throws -> [String: [String: Any]] {
      try XCTUnwrap(try listed(wc)[id]?["nodes"] as? [String: [String: Any]])
    }

    _ = try success(wc.controlPauseAutomation(automationId: id, nodeKey: "fetch", paused: true))
    XCTAssertEqual(try listed(wc)[id]?["paused"] as? Bool, false)
    XCTAssertEqual(try nodes()["fetch"]?["paused"] as? Bool, true)
    XCTAssertNil(try nodes()["fetch"]?["nextRunAt"])
    XCTAssertEqual(try nodes()["judge"]?["paused"] as? Bool, false)

    _ = try success(wc.controlPauseAutomation(automationId: id, nodeKey: "fetch", paused: false))
    XCTAssertEqual(try nodes()["fetch"]?["paused"] as? Bool, false)
    XCTAssertNotNil(try nodes()["fetch"]?["nextRunAt"])
    guard
      case .failure(let unknown) = wc.controlPauseAutomation(
        automationId: id, nodeKey: "nope", paused: true)
    else { return XCTFail("知らない鍵を受けた") }
    XCTAssertEqual(unknown.code, -32004)
  }
}

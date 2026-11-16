import XCTest

@testable import Orbe

/// 試走と止めること——試走は本番でその自動化を流したときと同じノードを同じ順で動かす。
///
/// 壊れると何が起きるか: 止めた自動化の試走が終わらない、または本番の流しと違うノードが動く。前からの未処理を持つ「届いたら」が
/// 試走の始めに古い行だけで先に走り、試走の回の並びと agent の費用が本番の流しと変わる。
extension AutomationTrialTests {
  private func item(_ id: String, at date: Date) -> AutomationItem {
    AutomationItem(id: id, link: "https://example.com/\(id)", body: "\(id) の本文", time: date)
  }

  /// 前からの未処理を持つ「届いたら」は、写しの上で走らせ役を立てたときに先に走らず、上流の後に 1 回だけ、前からの行と
  /// 上流が出した行を一緒に読む（本番で流したときと同じ）。
  func testAnArrivalNodeWithOldRowsWaitsForItsUpstreamInATrial() throws {
    let id = try define([
      fetch("gh"), definitionNode("p", .arrival, from: ["gh"], deliver: .report),
    ])
    try store.record(
      id, nodeKey: "gh", at: now, outcome: DesignSceneFixtures.fetched([item("x", at: now)]))
    now = now.addingTimeInterval(60)

    let trial = try trials.start(.saved(id), .init())
    waitCalls("gh", 1)
    XCTAssertEqual(calls("p"), [], "上流が終わるまで走らない")
    finish("gh", fetched(["x", "y"]))
    waitCalls("p", 1)
    XCTAssertEqual(ids("p"), [downstream("gh", "x", of: id), downstream("gh", "y", of: id)])
    finish("p", "要約")
    ended(trial)

    XCTAssertEqual(calls("p").count, 1)
  }

  /// 止めた自動化の試走は、本番で流したときと同じく、止めた「届いたら」を上流の後に 1 回だけ起こして終わる。本番は止めた
  /// ままで変わらない。
  func testATrialOfAPausedAutomationRunsLikeAFlowOfIt() throws {
    let id = try define([
      fetch("gh"), fetch("backlog"),
      definitionNode("digest", .arrival, from: ["gh", "backlog"], deliver: .report),
    ])
    _ = try runner.pause(id, true)
    let before = store.automations

    let trial = try trials.start(.saved(id), .init())
    waitCalls("gh", 1)
    waitCalls("backlog", 1)
    finish("gh", fetched(["a"]))
    XCTAssertEqual(calls("digest"), [], "上流がすべて終わるまで起こさない")
    finish("backlog", fetched(["b"]))
    waitCalls("digest", 1)
    finish("digest", "要約")
    ended(trial)

    XCTAssertEqual(calls("digest").count, 1)
    XCTAssertNil(trial.failure)
    XCTAssertEqual(store.automations, before, "本番は止めたまま変わらない")
  }
}

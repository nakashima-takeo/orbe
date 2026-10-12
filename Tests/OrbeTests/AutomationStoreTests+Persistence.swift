import XCTest

@testable import Orbe

/// 自動化と候補の永続——再起動で同じ状態に戻ること。
extension AutomationStoreTests {
  func testStateSurvivesARestart() throws {
    let store = try store(automations: 2)
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    _ = try store.setPaused(1, true)
    var steps = Self.definition("受信 2")
    steps.steps = [
      AutomationStep(
        name: "絞り込み", method: .command(BackgroundCommand(script: "jq -c .", directory: "/tmp"))),
      AutomationStep(
        name: "判定",
        method: .agent(AutomationStepAgent(cli: "claude", model: nil, instruction: "判定して"))),
    ]
    _ = try store.replace(2, with: steps)

    let reloaded = AutomationStore()

    XCTAssertEqual(reloaded.automations, store.automations)
    XCTAssertEqual(reloaded.proposals, store.proposals)
    XCTAssertEqual(try reloaded.create(Self.definition(), now: t0).id, 3, "採番位置も戻る")
  }
}

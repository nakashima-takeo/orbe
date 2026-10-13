import XCTest

@testable import Orbe

/// 採用・見送りの累計——人が候補をさばいた数を、候補を出した自動化に数えて持つ。
///
/// 壊れると何が起きるか: 候補が取得から消えるたびに数が減り、自動化の出す候補が役に立っているかを読めない。棚を移った候補を
/// 棚の自動化に数えて、役に立たない候補を出す自動化の数が良く見える。判定の「対応済み」まで見送りに数え、人の判断と混ざる。
extension AutomationStoreTests {
  private func tally(_ store: AutomationStore, _ id: Int) -> AutomationTaskCandidatesState? {
    guard case .taskCandidates(let state) = store.automation(id)?.sinkState else { return nil }
    return state
  }

  private func accept(_ store: AutomationStore, _ proposalId: Int) throws {
    _ = try store.accept(proposalId, into: TaskStore(file: nil), workspace: nil, at: .end)
  }

  /// さばくたびに出した自動化の数が 1 増え、候補を忘れても減らず、再起動しても残る。
  func testHandlingAProposalCountsItOnTheProposingAutomation() throws {
    let store = try store(automations: 2)
    let items = ["a", "b", "c"].map { Self.item($0) }
    commit(store, 1, fetched: items, proposing: items)
    XCTAssertEqual(tally(store, 1), AutomationTaskCandidatesState(), "まだ何もさばいていなければ 0 / 0")

    try accept(store, store.proposals[0].id)
    try store.dismiss(store.proposals[1].id)
    try store.dismiss(store.proposals[2].id)
    commit(store, 1, fetched: [])

    XCTAssertTrue(store.proposals.isEmpty)
    XCTAssertEqual(tally(store, 1), AutomationTaskCandidatesState(accepted: 1, dismissed: 2))
    XCTAssertEqual(tally(store, 2), AutomationTaskCandidatesState(), "ほかの自動化には数えない")
    XCTAssertEqual(tally(AutomationStore(), 1), tally(store, 1), "再起動しても残る")
  }

  /// 棚を移った候補は、棚の自動化ではなく出した自動化に数える。出した自動化が居なければどこにも数えない。
  func testAProposalOnAnotherShelfCountsOnlyOnTheAutomationThatProposedIt() throws {
    let store = try store(automations: 3)
    let shared = Self.item("s")
    let other = Self.item("o")
    commit(store, 1, fetched: [shared, other], proposing: [shared, other])
    commit(store, 2, fetched: [shared])
    commit(store, 3, fetched: [other])
    commit(store, 1, fetched: [])
    XCTAssertEqual(store.shelf(of: store.proposals[0])?.id, 2)

    try store.dismiss(store.proposals[0].id)
    try store.delete(1)
    try accept(store, store.proposals[1].id)

    XCTAssertEqual(tally(store, 2), AutomationTaskCandidatesState())
    XCTAssertEqual(tally(store, 3), AutomationTaskCandidatesState())
    XCTAssertEqual(store.proposals.map(\.state.name), ["dismissed", "accepted"], "数えなくてもさばける")
  }

  /// 判定の「対応済み」と Orbe の下げは、人の判断ではないので数えない。
  func testResolvedAndWithdrawnProposalsAreNotCounted() throws {
    let store = try store()
    let a = Self.item("a")
    let b = Self.item("b")
    commit(store, 1, fetched: [a, b], proposing: [a, b])

    commit(store, 1, fetched: [a], resolving: [a.link])

    XCTAssertEqual(store.proposals.map(\.state), [.resolved])
    XCTAssertEqual(tally(store, 1), AutomationTaskCandidatesState())
  }

  /// 定義を書き換えても、出力先の種類が同じなら数は戻らない。
  func testRedefiningKeepsTheCountsWhileTheSinkStays() throws {
    let store = try store()
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    try store.dismiss(store.proposals[0].id)

    _ = try store.replace(1, with: Self.definition("受信 1", instruction: "別の指示"))

    XCTAssertEqual(tally(store, 1), AutomationTaskCandidatesState(dismissed: 1))
  }

  /// 出力先ごとの状態を書かない保存は、出力先の初めの状態として読む。
  func testAFileWithoutTheSinkStateLoadsAsTheInitialState() throws {
    let store = try store()
    let a = Self.item("a")
    commit(store, 1, fetched: [a], proposing: [a])
    try store.dismiss(store.proposals[0].id)
    let data = try Data(contentsOf: automationsFile())
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var automations = try XCTUnwrap(json["automations"] as? [[String: Any]])
    automations[0]["sinkState"] = nil
    json["automations"] = automations
    try JSONSerialization.data(withJSONObject: json).write(to: automationsFile())

    XCTAssertEqual(tally(AutomationStore(), 1), AutomationTaskCandidatesState())
  }
}

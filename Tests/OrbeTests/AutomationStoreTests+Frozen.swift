import Foundation
import XCTest

@testable import Orbe

/// 版 2 の自動化の DB の凍結フィクスチャ。表と列は版 2 の DDL のコピーで（Orbe の `schema` を読まない）、各 JSON 列の値は素の SQL で入れる。
///
/// 壊れると何が起きるか: 版を上げず移行も書かずに表・列・JSON 列の形を変えると、更新した利用者の DB が初回起動で丸ごと退避されて
/// 自動化を失うか、定義・回の記録・候補を黙って読み違える。このフィクスチャはこの形で凍結しておく（足した列や欄に合わせて書き換えない）。
extension AutomationStoreTests {
  /// 版 2 のフィクスチャの DB は退避されずに開き、定義・回の記録・候補・持ち越しを書いたとおりに読める。
  func testAVersionTwoDatabaseOpensWithItsDefinitionRunsAndProposals() throws {
    try FileManager.default.createDirectory(
      at: automationsFolder(), withIntermediateDirectories: true)
    try database().exec(
      AutomationVersionTwoFixture.schema + "\n" + AutomationVersionTwoFixture.rows
        + "\nPRAGMA user_version = 2;")

    let store = AutomationStore()

    XCTAssertTrue(store.available)
    XCTAssertEqual(try quarantined(), [], "退避しない")
    XCTAssertEqual(store.unreadable.count, 0, "定義を読める")
    XCTAssertEqual(store.unreadableProposals, [], "候補を読める")
    let automation = try XCTUnwrap(store.automation(1))
    let definition = try JSONSerialization.jsonObject(
      with: Data(AutomationVersionTwoFixture.definition.utf8))
    XCTAssertEqual(
      AutomationWire.object(automation.definition) as? NSDictionary, definition as? NSDictionary)
    XCTAssertTrue(automation.state(key: "post").paused)
    XCTAssertEqual(automation.state(key: "issues").breach?.id, 1)

    let records = automation.graph.nodes.flatMap { automation.state(key: $0.key).runs }
    XCTAssertEqual(records.filter { $0.run == nil }.map(\.id), [], "不明な記録にならない")
    let runs = Dictionary(
      uniqueKeysWithValues: records.compactMap { r in r.run.map { (r.id, $0) } })
    XCTAssertEqual(
      runs.mapValues(\.result),
      [
        1: .fetch(fresh: 2, duplicates: 0), 2: .fetch(fresh: 2, duplicates: 1),
        3: .process(fresh: 2, duplicates: 0), 4: .judge(proposed: 3, resolved: 0, dismissed: []),
        5: .sideEffect(count: 2), 6: .report(text: "課題は 2 件\n- a\n- b"),
        7: .work(text: "投稿した\n- #1", nothing: nil), 8: .work(text: nil, nothing: "投稿するものが無い"),
        9: .fetch(fresh: 1, duplicates: 0),
        10: .judge(
          proposed: 1, resolved: 1,
          dismissed: [AutomationDismissal(link: "https://example.com/a", why: .alreadyProposed)]),
        11: nil, 12: .report(text: nil),
      ])
    XCTAssertEqual(
      runs[1]?.breach?.lines, [AutomationBrokenLine(line: 3, fault: .missingKey("link"))])
    XCTAssertEqual(runs[10]?.dropped.counts, [.closed: 1, .replaced: 1, .overflow: 1, .lapsed: 1])
    XCTAssertEqual(runs[12]?.dropped.counts, [.expired: 1])
    XCTAssertEqual(runs[11]?.failure, .ended(detail: "boom"))
    XCTAssertEqual(runs[11]?.execution.ending, .timeLimit)
    let carried = try store.carried(1, "judge")
    XCTAssertEqual(carried.dropped.counts, [.expired: 1])
    XCTAssertEqual(carried.withdrawn, 1)

    let proposals = Dictionary(uniqueKeysWithValues: store.proposals.map { ($0.title, $0) })
    XCTAssertEqual(proposals["a を直す"]?.state, .accepted(taskId: 1))
    XCTAssertEqual(proposals["a を直す"]?.reason, "依頼されている")
    XCTAssertEqual(proposals["a を直す"]?.fields.body, "課題 a")
    let open = try XCTUnwrap(proposals["c をする"])
    XCTAssertEqual(open.state, .open)
    XCTAssertEqual(open.link, "https://example.com/c")
    XCTAssertEqual(open.due, TaskItem.DueDate(year: 2026, month: 11, day: 20))
    XCTAssertEqual(open.workspace, UUID(uuidString: "6F1C2D3E-4B5A-4C6D-8E7F-9A0B1C2D3E4F"))
  }
}

import Foundation
import XCTest

@testable import Orbe

/// 版 2 の自動化の DB の凍結フィクスチャ。DB は版 2 の表作りの文のコピー（Orbe の `schema` を読まない）と、素の SQL で入れた各 JSON 列の
/// 値で作る。コピーは Orbe の `schema` と文のまま照らす——開くときの形の照らし合わせは CHECK・部分索引の条件・生成列の式を見ないため。
///
/// 壊れると何が起きるか: 版を上げず移行も書かずに表・列・JSON 列の形を変えると、Orbe を更新した利用者の DB が更新後の初回起動で丸ごと退避されて
/// 自動化を失うか、定義・回の記録・候補を黙って読み違える。制約だけを変えると、古い制約のまま開いた DB で新しい値の書き込みが失敗する。
/// 表作りの文と行（`AutomationVersionTwoFixture`）はこの形で凍結しておく（表に足した列や JSON 列に足した欄に合わせて書き換えない）。
extension AutomationStoreTests {
  /// 版 2 のフィクスチャの表作りの文は、Orbe が DB を作る文と同じ（開くときの形の照らし合わせが見ない制約の変更もここで止める）。
  func testTheVersionTwoSchemaIsTheSchemaOrbeCreates() {
    XCTAssertEqual(
      AutomationVersionTwoFixture.schema, AutomationDatabase.schema,
      "版 2 の表作りの文（CHECK・部分索引の条件・生成列の式を含む）を変えるなら、版を上げて移行を書き、この照合を新しい版の凍結フィクスチャとの照合に移す")
  }

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
    XCTAssertEqual(store.unreadable, [], "定義を読める")
    XCTAssertEqual(store.unreadableProposals, [], "候補を読める")
    let automation = try XCTUnwrap(store.automation(1))
    let definition = try JSONSerialization.jsonObject(
      with: Data(readDefinition.utf8))
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
      runs.mapValues(\.taken),
      [1: nil, 2: nil, 3: 2, 4: 4, 5: 2, 6: 2, 7: nil, 8: nil, 9: nil, 10: 1, 11: nil, 12: 2])
    XCTAssertEqual(
      runs.mapValues(\.withdrawn),
      [1: 0, 2: 0, 3: 0, 4: nil, 5: nil, 6: nil, 7: nil, 8: nil, 9: 0, 10: nil, 11: nil, 12: nil])
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
    XCTAssertEqual(proposals["a を直す"]?.fields.time, Date(timeIntervalSince1970: 1_793_000_000))
    let open = try XCTUnwrap(proposals["c をする"])
    XCTAssertEqual(open.state, .open)
    XCTAssertEqual(open.link, "https://example.com/c")
    XCTAssertEqual(open.due, TaskItem.DueDate(year: 2026, month: 11, day: 20))
    XCTAssertEqual(open.workspace, UUID(uuidString: "6F1C2D3E-4B5A-4C6D-8E7F-9A0B1C2D3E4F"))
  }
}

/// フィクスチャの定義を、`set_automation` が受ける JSON の形で書いたもの（Orbe が足す `id` と、省略できる `agent` を含む）。
private let readDefinition = #"""
  {"name": "見本", "notify": "menuBar", "workspace": "6F1C2D3E-4B5A-4C6D-8E7F-9A0B1C2D3E4F",
   "nodes": [
    {"id": 1, "key": "issues", "name": "課題を取る", "trigger": {"kind": "interval", "minutes": 30},
     "command": "gh issue list", "directory": ".", "coverage": "currentSet"},
    {"id": 2, "key": "slack", "name": "Slack を取る",
     "trigger": {"kind": "cron", "expression": "0 9 * * 1-5"}, "agent": "claude", "model": "haiku",
     "tools": ["mcp__slack__search"], "instruction": "取る", "coverage": "newArrivals",
     "retentionDays": 14, "timeoutMinutes": 5},
    {"id": 3, "key": "filter", "name": "絞る", "trigger": {"kind": "arrival"},
     "from": [{"node": "slack", "maxAgeHours": 48}], "command": "jq -c .", "directory": "."},
    {"id": 4, "key": "judge", "name": "判定", "trigger": {"kind": "arrival"},
     "from": ["issues", "filter"], "maxItems": 20, "agent": "claude", "model": "sonnet",
     "instruction": "決める", "deliver": "taskCandidates"},
    {"id": 5, "key": "digest", "name": "要約", "trigger": {"kind": "cron", "expression": "0 18 * * *"},
     "from": [{"node": "issues", "take": "all", "maxAgeHours": 24}], "agent": "claude",
     "model": "haiku", "instruction": "要約する", "deliver": "report"},
    {"id": 6, "key": "post", "name": "投稿", "trigger": {"kind": "manual"}, "agent": "claude",
     "model": "sonnet", "tools": ["Bash(gh search prs:*)"], "instruction": "投稿する",
     "deliver": "report"},
    {"id": 7, "key": "send", "name": "送る", "trigger": {"kind": "arrival"}, "from": ["filter"],
     "command": "~/bin/send.sh", "directory": "bin", "deliver": "none", "timeoutMinutes": 3}
   ]}
  """#

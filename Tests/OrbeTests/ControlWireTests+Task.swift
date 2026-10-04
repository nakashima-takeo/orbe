import Foundation
import XCTest

@testable import Orbe

/// タスクの 5 動詞の params の語と型検査。method 名・必須キー・型違い・ドメイン失敗の素通しは
/// `+Params` / `+Methods` の表が持ち、ここはそれで測れない「キーが無い」と `null` の区別、
/// 語彙の外の値、`move_task` の相対位置を見る。
///
/// 壊れると何が起きるか: `null`（外す）を「キー無し（変えない）」と取り違えると、`orb task set --no-due`
/// が成功を返しながら期限を残す。省いた workspace を「なし」と取り違えると、タブ内の agent が足した
/// タスクが自分の workspace から外れる。語彙の外のステータスや暦に無い日付が素通りすると、ストアへ
/// 届く前に既定値へ落ちたり、保存した tasks.json が次の起動で読めなくなったりする。
extension ControlWireTests {
  private func describe<Value>(_ value: ClearableValue<Value>?) -> String {
    switch value {
    case nil: return "omitted"
    case .clear: return "clear"
    case .set(let v): return "set(\(v))"
    }
  }

  func testAddTaskCarriesEveryFieldToTheTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    let response = wire.request(
      id: 1, method: "add_task", params: fixtures(fake)["add_task"] ?? [:])

    XCTAssertNil(response?["error"])
    let added = fake.addedTasks.last
    XCTAssertEqual(added?.draft.title, "経費精算")
    XCTAssertEqual(added?.draft.status, .inProgress)
    XCTAssertEqual(added?.draft.priority, .high)
    XCTAssertEqual(added?.draft.due?.text, "2026-10-06")
    XCTAssertEqual(added?.draft.waitingReason, "返事")
    XCTAssertEqual(added?.draft.memo, "メモ")
    XCTAssertEqual(describe(added?.workspaceId), "set(3)")
    XCTAssertEqual(added?.callerTabId, fake.tabId, "呼び出し元タブは target が解決できるよう届く")
  }

  func testAddTaskOmittedFieldsKeepTheirDefaults() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(id: 1, method: "add_task", params: ["title": "a"])

    let added = fake.addedTasks.last
    XCTAssertEqual(added?.draft.status, .todo)
    XCTAssertEqual(added?.draft.priority, .medium)
    XCTAssertNil(added?.draft.due)
    XCTAssertNil(added?.draft.waitingReason)
    XCTAssertEqual(added?.draft.memo, "")
    XCTAssertNil(added?.callerTabId)
  }

  /// workspace は「省略」「null」「id」の 3 値。add では省略が呼び出し元タブの workspace、update では
  /// 省略が「変えない」になるので、どちらも null と区別して target へ届く必要がある。
  func testWorkspaceIdDistinguishesOmittedNullAndAnId() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let cases: [(params: [String: Any], expected: String)] = [
      ([:], "omitted"), (["workspaceId": NSNull()], "clear"), (["workspaceId": 5], "set(5)"),
    ]

    for (index, entry) in cases.enumerated() {
      _ = wire.request(
        id: index * 2, method: "add_task",
        params: entry.params.merging(["title": "a"]) { a, _ in a })
      _ = wire.request(
        id: index * 2 + 1, method: "update_task",
        params: entry.params.merging(["taskId": 7, "memo": "m"]) { a, _ in a })
      XCTAssertEqual(
        describe(fake.addedTasks.last?.workspaceId), entry.expected, "add_task: \(entry.params)")
      XCTAssertEqual(
        describe(fake.updatedTasks.last?.workspaceId), entry.expected,
        "update_task: \(entry.params)")
    }
  }

  func testUpdateTaskDistinguishesOmittedAndNullForClearableFields() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "update_task",
      params: ["taskId": 7, "due": NSNull(), "waitingReason": NSNull()])
    let cleared = fake.updatedTasks.last
    XCTAssertEqual(cleared?.taskId, 7)
    XCTAssertEqual(describe(cleared?.update.due), "clear", "due: null は期限を外す")
    XCTAssertEqual(describe(cleared?.update.waitingReason), "clear", "waitingReason: null は待ちを外す")
    XCTAssertNil(cleared?.update.title, "渡していない項目は変えない")
    XCTAssertNil(cleared?.update.status)
    XCTAssertNil(cleared?.update.priority)
    XCTAssertNil(cleared?.update.memo)

    _ = wire.request(
      id: 2, method: "update_task",
      params: [
        "taskId": 8, "title": "t", "status": "done", "priority": "low", "due": "2028-02-29",
        "waitingReason": "返事", "memo": "",
      ])
    let set = fake.updatedTasks.last
    XCTAssertEqual(set?.taskId, 8)
    XCTAssertEqual(set?.update.title, "t")
    XCTAssertEqual(set?.update.status, .done)
    XCTAssertEqual(set?.update.priority, .low)
    XCTAssertEqual(set?.update.due?.value?.text, "2028-02-29")
    XCTAssertEqual(set?.update.waitingReason?.value, "返事")
    XCTAssertEqual(set?.update.memo, "", "空のメモは「変えない」ではなく空への置き換え")
  }

  func testMoveTaskTakesExactlyOneOfBeforeOrAfter() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(id: 1, method: "move_task", params: ["taskId": 7, "beforeTaskId": 8])
    _ = wire.request(id: 2, method: "move_task", params: ["taskId": 9, "afterTaskId": 10])
    XCTAssertEqual(fake.movedTasks.map(\.taskId), [7, 9])
    XCTAssertEqual(fake.movedTasks.map(\.placement), [.before, .after])
    XCTAssertEqual(fake.movedTasks.map(\.anchorTaskId), [8, 10])

    XCTAssertEqual(
      errorCode(wire.request(id: 3, method: "move_task", params: ["taskId": 7])), -32602,
      "どちらも無ければ -32602")
    XCTAssertEqual(
      errorCode(
        wire.request(
          id: 4, method: "move_task", params: ["taskId": 7, "beforeTaskId": 8, "afterTaskId": 9])),
      -32602, "両方あれば -32602")
    XCTAssertEqual(fake.movedTasks.count, 2, "拒否した要求は target へ届かない")
  }

  func testValuesOutsideTheVocabularyAreRejectedBeforeReachingTheTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let rejected: [(method: String, params: [String: Any])] = [
      ("add_task", ["title": "a", "status": "finished"]),
      ("add_task", ["title": "a", "priority": "urgent"]),
      ("add_task", ["title": "a", "due": "2026-02-30"]),
      ("add_task", ["title": "a", "due": "2026-2-3"]),
      ("add_task", ["title": "a", "due": "2026-10-06T00:00:00Z"]),
      ("add_task", ["title": "a", "workspaceId": true]),
      ("update_task", ["taskId": 7, "status": "DONE"]),
      ("update_task", ["taskId": 7, "due": "tomorrow"]),
      ("update_task", ["taskId": true, "memo": "m"]),
      ("list_tasks", ["workspaceId": "3"]),
      ("move_task", ["taskId": 7, "beforeTaskId": false]),
      ("delete_task", ["taskId": 7.5]),
    ]

    for (index, entry) in rejected.enumerated() {
      XCTAssertEqual(
        errorCode(wire.request(id: index, method: entry.method, params: entry.params)), -32602,
        "\(entry.method) \(entry.params) は -32602")
    }
    XCTAssertTrue(fake.addedTasks.isEmpty)
    XCTAssertTrue(fake.updatedTasks.isEmpty)
    XCTAssertTrue(fake.taskLists.isEmpty)
    XCTAssertTrue(fake.movedTasks.isEmpty)
    XCTAssertTrue(fake.deletedTaskIds.isEmpty)
  }

  /// `links` は `{kind, repo, number}` の配列で、順を保って届く。update では省略が「変えない」、`[]` が全部外す。
  func testLinksReachTheTargetInOrderAndAnEmptyListIsDistinctFromOmitted() throws {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let links: [[String: Any]] = [
      ["kind": "pr", "repo": "Owner/Repo.js", "number": 214],
      ["kind": "issue", "repo": "o/n", "number": 221],
    ]
    let expected = [
      TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "owner/repo.js", number: 214)), kind: .pr),
      TaskLink(item: try XCTUnwrap(GitHubItemID(repo: "o/n", number: 221)), kind: .issue),
    ]

    _ = wire.request(id: 1, method: "add_task", params: ["title": "a", "links": links])
    _ = wire.request(id: 2, method: "update_task", params: ["taskId": 7, "links": links])
    _ = wire.request(id: 3, method: "update_task", params: ["taskId": 7, "links": [Any]()])
    _ = wire.request(id: 4, method: "update_task", params: ["taskId": 7, "memo": "m"])

    XCTAssertEqual(fake.addedTasks.last?.draft.links, expected)
    XCTAssertEqual(fake.updatedTasks.map(\.update.links), [expected, [], nil])
  }

  /// 配列でない `links`（`null` を含む）と、形・範囲の合わない要素は、target へ届く前に -32602。
  func testMalformedLinksAreRejectedBeforeReachingTheTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let valid: [String: Any] = ["kind": "issue", "repo": "o/n", "number": 1]
    let malformed: [Any] = [
      NSNull(), valid, "o/n#1", [NSNull()], ["o/n#1"],
      [valid.merging(["kind": "discussion"]) { $1 }],
      [valid.merging(["repo": "orbe"]) { $1 }],
      [valid.merging(["repo": "o/n/x"]) { $1 }],
      [valid.merging(["repo": "o/"]) { $1 }],
      [valid.merging(["repo": "o n/x"]) { $1 }],
      [valid.merging(["number": 0]) { $1 }],
      [valid.merging(["number": "1"]) { $1 }],
      [valid.merging(["number": 1.5]) { $1 }],
      [valid.merging(["number": true]) { $1 }],
      [valid.filter { $0.key != "kind" }],
    ]

    for (index, links) in malformed.enumerated() {
      XCTAssertEqual(
        errorCode(
          wire.request(id: index * 2, method: "add_task", params: ["title": "a", "links": links])),
        -32602, "add_task links: \(links) は -32602")
      XCTAssertEqual(
        errorCode(
          wire.request(
            id: index * 2 + 1, method: "update_task", params: ["taskId": 7, "links": links])
        ),
        -32602, "update_task links: \(links) は -32602")
    }
    XCTAssertTrue(fake.addedTasks.isEmpty)
    XCTAssertTrue(fake.updatedTasks.isEmpty)
  }

  func testListAndDeleteCarryTheirIdsToTheTarget() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(id: 1, method: "list_tasks")
    _ = wire.request(id: 2, method: "list_tasks", params: ["workspaceId": 6])
    _ = wire.request(id: 3, method: "delete_task", params: ["taskId": 11])

    XCTAssertEqual(fake.taskLists, [nil, 6], "workspaceId の省略は絞り込まない")
    XCTAssertEqual(fake.deletedTaskIds, [11])
  }
}

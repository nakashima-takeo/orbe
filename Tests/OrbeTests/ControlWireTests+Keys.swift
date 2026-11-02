import Foundation
import XCTest

@testable import Orbe

/// 動詞の表が受け口の唯一の振り分けで、どの動詞も知らない鍵と型の違う値を場所付きで断ること。要求の封筒（`params` の形と
/// `caller`）の断りと、無応答の動詞が断るべき要求を何もしないこと。
///
/// 壊れると何が起きるか: 書き損じた鍵（`partKey`）や古い名前の鍵が黙って読み捨てられ、`run_automation` が終わりのノード
/// すべてまで流れる。型の違う値（`{"scrollback": "true"}`・`{"cwd": 123}`）が省略と読まれ、既定に倒れる。表にあって
/// ハンドラが読まない鍵は、型を違えても断られないので、ここで落ちる。
extension ControlWireTests {
  /// 表の動詞は、spec の socket メソッドの表（`validRequests`）と、そこに載らない待機・無応答の 3 つでちょうど尽きる。
  func testTheVerbTableIsTheSocketMethods() {
    let listed = Set(validRequests(FakeControlTarget()).map(\.method))
    XCTAssertEqual(
      Set(ControlServer.verbs.keys), listed.union(["wait_for_event"]).union(silentMethods))
  }

  private var silentMethods: Set<String> {
    Set(
      ControlServer.verbs.compactMap { method, verb in
        if case .silent = verb.reply { return method }
        return nil
      })
  }

  /// 応答する動詞と、その正しい params 一式（`wait_for_event` は最短の待ちに向ける）。
  private func answeringRequests(_ fake: FakeControlTarget) -> [(
    method: String, params: [String: Any]
  )] {
    validRequests(fake) + [("wait_for_event", ["timeoutMs": 1])]
  }

  private func message(_ response: [String: Any]?) -> String? {
    (response?["error"] as? [String: Any])?["message"] as? String
  }

  /// どの動詞も、受けない鍵を 1 つ足した要求を `-32602 unknown <鍵>` で断り、ハンドラへ渡さない。
  func testEveryVerbRejectsAKeyItDoesNotTake() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    for (index, entry) in answeringRequests(fake).enumerated() {
      var params = entry.params
      params["partKey"] = "judge"
      let response = wire.request(id: index, method: entry.method, params: params)
      XCTAssertEqual(errorCode(response), -32602, entry.method)
      XCTAssertEqual(message(response), "unknown partKey", entry.method)
    }
  }

  /// 知らない鍵で断った要求は何も変えない。
  func testAKeyNotTakenChangesNothing() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(
      id: 1, method: "run_automation", params: ["automationId": 2, "partKey": "judge"])
    _ = wire.request(
      id: 2, method: "add_task", params: ["title": "a", "workspace": Self.workspace])
    _ = wire.request(
      id: 3, method: "spawn", params: ["dir": "/tmp"])

    XCTAssertTrue(fake.ranAutomations.isEmpty, "行き先を読み捨てて終わりのノードまで流さない")
    XCTAssertTrue(fake.addedTasks.isEmpty)
    XCTAssertTrue(fake.spawns.isEmpty, "ホームで開かない")
  }

  /// どの動詞のどの引数も、型の違う値を `-32602 invalid <鍵>` で断る。宛先を解く前に断るので、タブを指す動詞には
  /// 無いタブを向けても型の断りが返る。ハンドラが読まない鍵はここで落ちる（読まれなければ断られない）。
  func testEveryArgumentOfEveryVerbRejectsAValueOfTheWrongType() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    var id = 0

    for entry in answeringRequests(fake) {
      guard let verb = ControlServer.verbs[entry.method] else {
        XCTFail("\(entry.method) が表に無い")
        continue
      }
      for (key, type) in verb.params {
        guard let wrong = Self.wrongValue(for: type) else { continue }
        var params = entry.params
        if key != "tabId", params["tabId"] != nil { params["tabId"] = 999_999 }
        params[key] = wrong
        id += 1
        let response = wire.request(id: id, method: entry.method, params: params)
        XCTAssertEqual(errorCode(response), -32602, "\(entry.method).\(key)")
        XCTAssertEqual(message(response), "invalid \(key)", "\(entry.method).\(key)")
      }
    }
  }

  /// 型に合わない値。型を問わない値は無い。正しい値を隣の型へ移した値（整数には数字の文字列、文字列には数）にする——どの型にも
  /// ならない値だけだと、読みを片側へ緩める改変（CLI が文字列で送る `tabId` に合わせて数字の文字列を許すなど）が通る。
  private static func wrongValue(for type: ControlParamType) -> Any? {
    switch type {
    case .int: "1"
    case .bool: 1
    case .string, .workspaceId: 1
    case .strings, .object, .objects: "x"
    case .any: nil
    case .clearable(let type): wrongValue(for: type)
    }
  }

  /// `params` はオブジェクトだけを受け、省いた要求は引数なし。知らない method は params の形によらず -32601。
  func testParamsMustBeAnObject() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    for (index, params) in ([[1], 1, "x", true, NSNull()] as [Any]).enumerated() {
      wire.send(["jsonrpc": "2.0", "id": index, "method": "list_workspaces", "params": params])
      let response = wire.nextResponse()
      XCTAssertEqual(errorCode(response), -32602, "\(params)")
      XCTAssertEqual(message(response), "invalid params", "\(params)")
    }
    wire.send(["jsonrpc": "2.0", "id": 9, "method": "no_such_verb", "params": [1]])
    XCTAssertEqual(errorCode(wire.nextResponse()), -32601, "method 名だけで決まる")
  }

  /// 呼び出し元のタブは封筒の `caller: {tabId}` で伝え、引数の `callerTabId` は知らない鍵。読まない動詞は封筒を使わない。
  func testTheCallerTabRidesOnTheEnvelope() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    _ = wire.request(id: 1, method: "add_task", params: ["title": "a"], callerTabId: 5)
    XCTAssertEqual(fake.addedTasks.last?.callerTabId, 5)
    XCTAssertNil(errorCode(wire.request(id: 2, method: "list_tasks", callerTabId: 5)))

    let spoofed = wire.request(id: 3, method: "add_task", params: ["title": "a", "callerTabId": 5])
    XCTAssertEqual(message(spoofed), "unknown callerTabId")

    let callers: [Any] = [
      5, "5", [String: Any](), ["tabId": "5"], ["tabId": true], ["tabId": 5, "x": 1],
    ]
    for (index, caller) in callers.enumerated() {
      wire.send([
        "jsonrpc": "2.0", "id": 10 + index, "method": "add_task", "params": ["title": "a"],
        "caller": caller,
      ])
      let response = wire.nextResponse()
      XCTAssertEqual(errorCode(response), -32602, "\(caller)")
      XCTAssertEqual(message(response), "invalid caller", "\(caller)")
    }
    XCTAssertEqual(fake.addedTasks.count, 1, "断った要求はタスクを足さない")
  }

  /// 入れ子のオブジェクト（待ちの条件・結び付きの要素）の知らない鍵は、場所付きで断る。
  func testNestedObjectsRejectKeysTheyDoNotTake() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let condition: [String: Any] = [
      "description": "d", "command": "true", "everyMinutes": 10,
      "deadline": "2099-01-01T00:00:00Z", "directory": "/tmp",
    ]
    let links: [[String: Any]] = [
      ["kind": "pr", "repo": "o/n", "number": 1],
      ["kind": "pr", "repo": "o/n", "number": 2, "url": "https://github.com/o/n/pull/2"],
    ]

    XCTAssertEqual(
      message(
        wire.request(
          id: 1, method: "set_wait_condition", params: ["taskId": 7, "condition": condition])),
      "unknown condition.directory")
    XCTAssertEqual(
      message(wire.request(id: 2, method: "add_task", params: ["title": "a", "links": links])),
      "unknown links[1].url")
    XCTAssertEqual(
      message(
        wire.request(
          id: 3, method: "update_task",
          params: ["taskId": 7, "links": [["kind": "pr", "repo": "o/n"]]])),
      "missing links[0].number")
    XCTAssertTrue(fake.setWaitConditions.isEmpty)
    XCTAssertTrue(fake.addedTasks.isEmpty)
    XCTAssertTrue(fake.updatedTasks.isEmpty)
  }

  /// 無応答の動詞は、知らない鍵・型違い・オブジェクトでない params・形の誤った封筒でも応答を書かない。
  func testSilentVerbsWriteNothingForRequestsTheyRefuse() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)

    for method in silentMethods {
      let refused: [Any] = [["tabId": fake.tabId, "partKey": 1], ["tabId": "\(fake.tabId)"], 1]
      for params in refused {
        wire.send(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
      }
      wire.send([
        "jsonrpc": "2.0", "id": 2, "method": method, "params": ["tabId": fake.tabId],
        "caller": "x",
      ])
    }
    wire.barrier()
  }
}

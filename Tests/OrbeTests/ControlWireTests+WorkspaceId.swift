import Foundation
import XCTest

@testable import Orbe

extension ControlWireTests {
  /// workspaceId を読む動詞は、どれも同じ読み口を通る。整数・真偽値・UUID でない文字列は、省略できる動詞でも省略と同じに
  /// せず -32602。`null` で「なし」にできるのはタスクの付き先だけ。小文字で書いた ID も同じ ID として届く。
  ///
  /// 壊れると何が起きるか: 型違いの値が省略と読まれ、アクティブな workspace に黙ってタブが開き、設定が書き換わる。
  func testEveryVerbReadsWorkspaceIdTheSameWay() {
    let fake = FakeControlTarget()
    let wire = startWire(target: fake)
    let verbs =
      validRequests(fake).filter { $0.params["workspaceId"] != nil }
      + [("update_task", ["taskId": 7, "workspaceId": Self.workspace])]
    XCTAssertEqual(
      Set(verbs.map(\.method)),
      [
        "list_tabs", "spawn", "spawn_agent", "resume_agent", "activate_workspace", "config_list",
        "config_set",
        "rename_workspace", "set_workspace_root", "remove_workspace", "list_tasks", "add_task",
        "update_task", "list_board_widgets", "add_board_widget", "remove_board_widget",
      ], "workspaceId を読む動詞の全部")

    let clearable: Set<String> = ["add_task", "update_task"]
    for (method, params) in verbs {
      let bad: [(String, Any)] =
        [("整数", 3), ("真偽値", true), ("UUID でない文字列", "3")]
        + (clearable.contains(method) ? [] : [("null", NSNull())])
      for (label, value) in bad {
        var sent = params
        sent["workspaceId"] = value
        let response = wire.request(id: 1, method: method, params: sent)
        XCTAssertEqual(errorCode(response), -32602, "\(method): \(label)")
        XCTAssertEqual(
          (response?["error"] as? [String: Any])?["message"] as? String, "invalid workspaceId",
          "\(method): \(label)")
      }
    }

    let workspace = UUID()
    _ = wire.request(
      id: 2, method: "spawn", params: ["workspaceId": workspace.uuidString.lowercased()])
    XCTAssertEqual(fake.spawns.last?.workspaceId, workspace, "小文字でも同じ ID")
    _ = wire.request(id: 3, method: "list_tabs", params: ["workspaceId": workspace.uuidString])
    XCTAssertEqual(fake.tabLists.last, workspace, "list_tabs の絞り込みも target が解く")
  }
}

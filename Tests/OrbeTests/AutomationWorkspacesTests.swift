import XCTest

@testable import Orbe

/// 定義の workspace の席の、外の形（起動ごとの ID）と保存の形（永続 ID）の写し。入口は整数でない値・`null`・知らない ID を
/// 定義の中の場所で断る。
///
/// 壊れると何が起きるか: 永続 ID が外に漏れ、AI が書いた起動ごとの ID が再起動で別の workspace を指す。消えた workspace の席の
/// 書き戻しが通り、黙って自動化の workspace に付け替わって別のリポジトリで走る。真偽値や文字列が workspace として通る。
final class AutomationWorkspacesTests: OrbeTestCase {
  private let home = AutomationWorkspace(id: 1, persistentId: UUID(), name: "Home", root: "/h")
  private let orbe = AutomationWorkspace(id: 3, persistentId: UUID(), name: "orbe", root: "/src")
  private var workspaces: AutomationWorkspaces { AutomationWorkspaces(all: [home, orbe], home: 1) }

  private func definition(_ top: Any?, _ node: Any?) -> [String: Any] {
    var command: [String: Any] = ["key": "a", "command": "pwd"]
    command["workspace"] = node
    var definition: [String: Any] = ["name": "x", "nodes": [["key": "r"], command]]
    definition["workspace"] = top
    return definition
  }

  private func seats(_ definition: [String: Any]) -> [String] {
    let nodes = definition["nodes"] as? [[String: Any]] ?? []
    return ([definition["workspace"]] + nodes.map { $0["workspace"] }).map { "\($0 ?? "-")" }
  }

  func testTheSeatsGoInAsPersistentIdsAndComeBackAsTheIdsOfThisLaunch() throws {
    let stored = try workspaces.inward(definition(3, 1))

    XCTAssertEqual(
      seats(stored), [orbe.persistentId.uuidString, "-", home.persistentId.uuidString],
      "Home も走る場所に書ける")
    XCTAssertEqual(seats(workspaces.outward(stored)), ["3", "-", "1"])
    XCTAssertEqual(seats(try workspaces.inward(definition(nil, nil))), ["-", "-", "-"])
  }

  func testAnUnusableSeatIsRefusedAtItsPlace() {
    for (label, object, message) in [
      (
        "整数でない", definition(nil, "3"),
        "invalid nodes[1].workspace: pass a workspace id from list_workspaces"
      ),
      ("真偽値", definition(true, nil), "invalid workspace: pass a workspace id from list_workspaces"),
      ("知らない ID", definition(nil, 7), "nodes[1].workspace: unknown workspace 7"),
      (
        "自動化の workspace があるノードの null", definition(3, NSNull()),
        "nodes[1].workspace: null names no workspace (a removed workspace is listed as null); pass a "
          + "workspace id from list_workspaces, or leave workspace out to run in the automation's "
          + "workspace"
      ),
      (
        "自動化の workspace が無いノードの null", definition(nil, NSNull()),
        "nodes[1].workspace: null names no workspace (a removed workspace is listed as null); pass a "
          + "workspace id from list_workspaces, or leave workspace out and give the node an absolute "
          + "directory"
      ),
    ] {
      XCTAssertThrowsError(try workspaces.inward(object), label) {
        XCTAssertEqual($0 as? AutomationError, .invalid(message), label)
      }
    }
  }
}

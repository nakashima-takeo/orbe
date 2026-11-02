import XCTest

@testable import Orbe

/// 定義の workspace の席（最上位とコマンドのノード）。読みは UUID の文字列だけを受け、`null`・整数・UUID でない値を定義の中の
/// 場所で断る。書くときは、席が今の workspace を指すかを確かめ、無い席を場所付きで断る。
///
/// 壊れると何が起きるか: 消えた workspace の席の書き戻しが通り、黙って自動化の workspace に付け替わって別のリポジトリで走る。
/// `null` や真偽値が「書かない」や別の workspace として通る。
final class AutomationWorkspacesTests: OrbeTestCase {
  private let home = AutomationWorkspace(id: UUID(), name: "Home", root: "/h")
  private let orbe = AutomationWorkspace(id: UUID(), name: "orbe", root: "/src")
  private var workspaces: AutomationWorkspaces {
    AutomationWorkspaces(all: [home, orbe], home: home.id)
  }

  private func definition(_ top: Any?, _ node: Any?) -> [String: Any] {
    func command(_ key: String) -> [String: Any] {
      ["key": key, "name": key, "trigger": ["kind": "manual"], "command": "pwd"]
    }
    var seated = command("a")
    seated["workspace"] = node
    var definition: [String: Any] = ["name": "x", "nodes": [command("r"), seated]]
    definition["workspace"] = top
    return definition
  }

  func testSeatsNamingCurrentWorkspacesAreAcceptedAndComeBackInTheStoredForm() throws {
    let read = try AutomationDefinition.decode(
      definition(orbe.id.uuidString.lowercased(), home.id.uuidString))

    XCTAssertNoThrow(try workspaces.checkSeats(of: read), "Home も走る場所に書ける")
    let written = try XCTUnwrap(AutomationWire.object(read) as? [String: Any])
    XCTAssertEqual(written["workspace"] as? String, orbe.id.uuidString, "小文字で書いても保存の形で返る")
    let nodes = try XCTUnwrap(written["nodes"] as? [[String: Any]])
    XCTAssertNil(nodes[0]["workspace"], "書かない席は書かないまま")
    XCTAssertEqual(nodes[1]["workspace"] as? String, home.id.uuidString)
  }

  func testAnUnknownSeatIsRefusedAtItsPlace() throws {
    let removed = UUID()
    let refusal = { (path: String, leftOut: String) in
      "\(path): unknown workspace \(removed.uuidString) (it may have been removed); pass a workspace id from "
        + "list_workspaces, or \(leftOut)"
    }
    for (label, object, message) in [
      (
        "自動化の席", definition(removed.uuidString, nil),
        refusal("workspace", "leave workspace out and give its command nodes absolute directories")
      ),
      (
        "自動化の workspace があるノードの席", definition(orbe.id.uuidString, removed.uuidString),
        refusal("nodes[1].workspace", "leave workspace out to run in the automation's workspace")
      ),
      (
        "自動化の workspace が無いノードの席", definition(nil, removed.uuidString),
        refusal("nodes[1].workspace", "leave workspace out and give the node an absolute directory")
      ),
    ] {
      let read = try AutomationDefinition.decode(object)
      XCTAssertThrowsError(try workspaces.checkSeats(of: read), label) {
        XCTAssertEqual($0 as? AutomationError, .invalid(message), label)
      }
    }
  }

  func testASeatThatIsNotAWorkspaceIdIsRefusedAtItsPlace() {
    let values: [(String, Any)] = [
      ("null", NSNull()), ("整数", 3), ("真偽値", true), ("UUID でない文字列", "3"),
    ]
    for (label, value) in values {
      XCTAssertThrowsError(try AutomationDefinition.decode(definition(value, nil)), label) {
        XCTAssertEqual($0 as? AutomationError, .invalid("invalid workspace"), "自動化の \(label)")
      }
      XCTAssertThrowsError(
        try AutomationDefinition.decode(definition(orbe.id.uuidString, value)), label
      ) {
        XCTAssertEqual(
          $0 as? AutomationError, .invalid("invalid nodes[1].workspace"), "ノードの \(label)")
      }
    }
  }
}

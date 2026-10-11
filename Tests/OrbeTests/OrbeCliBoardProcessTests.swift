import Foundation
import XCTest

@testable import Orbe

/// 実 `orb board`（`orbe-cli`）を子プロセスで起こし、実 `WindowController` の Home のボードの部品を list → rm → add で
/// 動かせることを固定する。
///
/// 壊れると何が起きるか: CLI が組み立てる control メソッド名・params の語（`workspaceId`・`kind`）はここでしか測れない。
/// `rm` が `add_board_part` を送ると、exit 0 を返しながら部品が残る。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続する（GhosttyKit 必須）。純ロジック検証ではない。
final class OrbeCliBoardProcessTests: OrbeTestCase {
  func testBoardSubcommandsListRemoveAndAddParts() throws {
    let control = try startControlProcess()
    let workspaces = try XCTUnwrap(
      control.orbJSON(["ws", "list"])["workspaces"] as? [[String: Any]])
    let home = try XCTUnwrap(
      workspaces.first { $0["hasBoard"] as? Bool == true }?["id"] as? Int,
      "ws list --json に hasBoard")
    func run(_ args: [String]) -> String {
      let outcome = control.orb(["board"] + args)
      XCTAssertEqual(outcome.status, 0, "orb board \(args) が exit 0 でない: \(outcome.stderr)")
      return outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    XCTAssertEqual(run(["list", "\(home)"]), "intake")
    XCTAssertEqual(run(["rm", "\(home)", "intake"]), "", "結果の並び（空）")
    XCTAssertEqual(run(["add", "\(home)", "intake"]), "intake")
    XCTAssertEqual(
      (control.orbJSON(["board", "list", "\(home)"])["parts"] as? [[String: Any]])?.count, 1)
    XCTAssertEqual(control.orb(["board", "add", "\(home)"]).status, 2, "種類の欠落は usage")
  }
}

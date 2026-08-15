import XCTest

@testable import Orbe

/// ペイン占有の worktree への帰属（`DispatchWorktreeClassifier.occupancies`）。
extension DispatchWorktreeClassifierTests {

  /// 子ディレクトリにいるペインも占有。判定はパス構成要素単位で、文字列 prefix ではない。
  func testOccupancyMatchesChildDirectoryButNotSiblingPrefix() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/foo"],
      panes: [PaneOccupancy(cwd: "/a/foo/src/deep", agentState: nil)])
    XCTAssertNotNil(map["/a/foo"], "子ディレクトリは占有")

    let sibling = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/foo"], panes: [PaneOccupancy(cwd: "/a/foobar", agentState: nil)])
    XCTAssertTrue(sibling.isEmpty, "接頭辞が一致するだけの兄弟は占有ではない")
  }

  /// 入れ子の worktree では最も長く一致した方に帰属する（親と子の両方を占有にしない）。
  func testOccupancyPrefersLongestMatch() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/a/repo", "/a/repo/wt/child"],
      panes: [PaneOccupancy(cwd: "/a/repo/wt/child/src", agentState: nil)])
    XCTAssertNil(map["/a/repo"])
    XCTAssertNotNil(map["/a/repo/wt/child"])
  }

  /// symlink（macOS の `/tmp` → `/private/tmp`）を解決してから突き合わせる。
  /// OSC 7 が報告する pwd と `git worktree list` のパスは素では一致しないことがある。
  func testOccupancyResolvesSymlinks() throws {
    let name = "orbe-occupancy-\(UUID().uuidString)"
    let path = "/tmp/\(name)"
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: [path],
      panes: [PaneOccupancy(cwd: "/private/tmp/\(name)", agentState: nil)])
    XCTAssertNotNil(map[path])
  }

  /// 同じ worktree に複数ペインが居たら waiting > working > done で 1 つに畳む。
  func testOccupancyFoldsByAgentPriority() {
    let map = DispatchWorktreeClassifier.occupancies(
      worktreePaths: ["/wt/x"],
      panes: [
        PaneOccupancy(cwd: "/wt/x", agentState: "done"),
        PaneOccupancy(cwd: "/wt/x/sub", agentState: "waiting"),
        PaneOccupancy(cwd: "/wt/x", agentState: "working"),
      ])
    XCTAssertEqual(map["/wt/x"]?.agentState, "waiting")
  }
}

import AppKit
import XCTest

@testable import Orbe

/// タブグループの配線を実 `WindowController` で端から端まで通す——復元時の正規化、⌘T の挿入位置と
/// 選択、cd（OSC 7）による再判定、セグメント移動、そして chrome への投影（`statusModel.strip`）。
///
/// 純ドメインの規則は `SessionStoreTabGroupTests` が持つ。ここが守るのはその外側——`openTab` が
/// 実挿入 index を select すること、`onPwdChange` が `regroup` に繋がり chrome と保存へ届くこと、
/// `onReorderSegment` が store へ届くこと。store がいくら固くても、配線が 1 本外れれば
/// 「⌘T で開いたタブが別の位置で選ばれる」「cd してもセグメントが動かない」形で機能が消える。
///
/// cwd は git 管理外の別ディレクトリを使う（キー＝cwd 自身）ので、実リポジトリは要らない。
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**。
final class WindowControllerTabGroupTests: OrbeTestCase {

  override func setUp() {
    super.setUp()
    AppStatePersistence.save(
      AppStateFile(cachedShellPath: "/usr/bin:/bin", preferredLanguage: "ja"))
  }

  private func restore(_ cwds: [String], activeTab: Int = 0) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: activeTab,
          tabs: cwds.map { TabState(cwd: $0, agent: nil, explicitTitle: nil) })
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  private func cwds(_ wc: WindowController) -> [String] { wc.current.tabs.map(\.cwd) }

  private func colorIndex(_ cwd: String) -> Int {
    WorktreeColor.index(forKey: GitWorktreeRoot.normalizedPath(cwd))
  }

  /// 保存ファイルに非隣接の同 worktree があれば復元で連へ寄せ、active は同じタブを指し、
  /// chrome には連と色番号が投影される。
  func testRestoreNormalizesAdjacencyAndProjectsSegments() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g2", "/tmp/g1", "/tmp/g3"], activeTab: 2)

    XCTAssertEqual(cwds(wc), ["/tmp/g1", "/tmp/g1", "/tmp/g2", "/tmp/g3"], "初出順で連へ")
    XCTAssertEqual(wc.current.active, 1, "保存時 index 2 のタブ（2 枚目の g1）を指し続ける")

    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.strip.ranges, [0..<2, 2..<3, 3..<4])
    XCTAssertEqual(
      wc.statusModel.strip.colorIndices, ["/tmp/g1", "/tmp/g2", "/tmp/g3"].map(colorIndex),
      "連ごとの色番号はその worktree キーから")
  }

  /// ⌘T は現在タブの cwd を継ぐので同 worktree の連の右端に生え、そのタブが選ばれる。
  func testNewTabLandsAtSegmentEndAndIsSelected() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g1", "/tmp/g2"], activeTab: 0)

    wc.newTab()

    XCTAssertEqual(cwds(wc), ["/tmp/g1", "/tmp/g1", "/tmp/g1", "/tmp/g2"], "g1 の連の右端（末尾ではない）")
    XCTAssertEqual(wc.current.active, 2, "生えたタブが選ばれる")
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.strip.ranges, [0..<3, 3..<4])
    XCTAssertEqual(wc.statusModel.active, 2)
  }

  /// 連の中のタブが cd で別 worktree へ出ると、その連の直右へ移り、chrome と保存順に反映される。
  func testPwdReportRegroupsTabAndReprojects() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g1", "/tmp/g1", "/tmp/g2"], activeTab: 1)
    let moved = wc.current.tabs[1]

    moved.surface.currentPwd = "/tmp/g3"  // OSC 7

    XCTAssertEqual(cwds(wc), ["/tmp/g1", "/tmp/g1", "/tmp/g3", "/tmp/g2"], "元の連の直右へ")
    XCTAssertTrue(wc.current.tabs[wc.current.active] === moved, "cd したタブを見続ける")
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.strip.ranges, [0..<2, 2..<3, 3..<4])
    XCTAssertEqual(wc.statusModel.active, 2)

    wc.flushSave()
    XCTAssertEqual(
      try XCTUnwrap(WorkspacePersistence.load()).workspaces[0].tabs.map(\.cwd),
      ["/tmp/g1", "/tmp/g1", "/tmp/g3", "/tmp/g2"], "新しい順で保存される")
  }

  /// バー掴みのドロップ（`onReorderSegment`）は連ごと動かし、chrome に新しい連が投影される。
  func testSegmentReorderMovesWholeRunAndReprojects() throws {
    let wc = try restore(["/tmp/g1", "/tmp/g1", "/tmp/g2"], activeTab: 0)
    let viewed = wc.current.tabs[0]

    wc.statusModel.onReorderSegment(0, 3)

    XCTAssertEqual(cwds(wc), ["/tmp/g2", "/tmp/g1", "/tmp/g1"], "g1 の連が末尾へ")
    XCTAssertTrue(wc.current.tabs[wc.current.active] === viewed, "active は同じタブ")
    wc.flushChrome()
    XCTAssertEqual(wc.statusModel.strip.ranges, [0..<1, 1..<3])
    XCTAssertEqual(wc.statusModel.active, 1)
  }
}

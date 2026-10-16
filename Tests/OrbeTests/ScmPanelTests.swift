import OrbeTestSupport
import XCTest

@testable import Orbe

/// 面ごとのソース管理パネル（実 git）: HEAD が push 済みかの追従・選んだ行が区分から消えたときの選び直し・一括操作と競合。
///
/// 壊れると何が起きるか。端末で push したコミットを amend・取り消しで書き換えられる（force push を持たないので Orbe の中では
/// 戻せない）。ステージした行の選択が消えて ↑↓ で見て回る位置を失う・選び直しで diff が勝手に開く。「すべてステージ」が
/// 競合の印の残ったファイルを解決済みにする・「すべて破棄」が競合中のファイルを捨てる。
@MainActor
final class ScmPanelTests: OrbeTestCase {
  var repo: TempGitRepo!
  var panel: ScmPanel!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  override func tearDown() {
    panel?.isShown = false
    panel?.isLive = false
    super.tearDown()
  }

  /// パネルを出し、`ready` が成り立つまで待つ。
  private func show(until ready: @escaping (ScmPanel) -> Bool, _ message: String) {
    panel = ScmPanel(root: repo.root)
    panel.isLive = true
    panel.isShown = true
    pumpMain(until: { ready(self.panel) }, message)
  }

  private func idle(_ message: String) {
    pumpMain(until: { self.panel.control.operations.isEmpty }, timeout: 20, message)
  }

  /// 端末で HEAD を upstream を付けずに push すると（status は変わらず ref だけが動く）、amend と取り消しは押せなくなる。
  func testAHeadPushedFromTheTerminalCanNoLongerBeRewritten() throws {
    repo.addOrigin()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "local"]).isSuccess)
    show(until: { $0.commitState.canUndo }, "未 push の HEAD は取り消せる")
    panel.control.message = "reword"
    XCTAssertTrue(panel.commitState.canAmend)

    XCTAssertTrue(repo.git(["push", "-q", "origin", "feat"]).isSuccess)
    pumpMain(until: { !self.panel.commitState.canUndo }, "push 済みの HEAD は取り消せない")
    XCTAssertFalse(panel.commitState.canAmend)
  }

  /// 選んだ行がステージで区分から消えたら、同じ区分のその位置の行（末尾なら前の行）が選ばれ、diff は開かない。
  func testStagingTheSelectedRowSelectsItsNeighbourWithoutOpening() throws {
    for name in ["x1.txt", "x2.txt", "x3.txt"] { try repo.write(name, "x\n") }
    show(until: { $0.changes.changes.count == 3 }, "変更の行")
    var opened = 0
    panel.onOpenDiff = { _, _ in opened += 1 }

    panel.select(ScmRowID(section: .changes, path: "x2.txt"))
    panel.control.stage([GitStatus.Row(path: "x2.txt", originalPath: nil)])
    pumpMain(until: { self.panel.changes.changes.count == 2 }, "x2 がステージ済みへ")
    XCTAssertEqual(panel.selection, ScmRowID(section: .changes, path: "x3.txt"))

    panel.control.stage([GitStatus.Row(path: "x3.txt", originalPath: nil)])
    pumpMain(until: { self.panel.changes.changes.count == 1 }, "x3 がステージ済みへ")
    XCTAssertEqual(panel.selection, ScmRowID(section: .changes, path: "x1.txt"))
    XCTAssertEqual(opened, 0)
  }

  /// 「すべて破棄」「すべてステージ」は競合中のファイルを含めない（競合の行は 1 行ずつステージで解決済みにする）。
  func testBulkActionsLeaveConflictedFilesAlone() throws {
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "b"]).isSuccess)
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "side"]).isSuccess)
    try repo.write("a.txt", "side\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "side"]).isSuccess)
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    try repo.write("a.txt", "main\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "main"]).isSuccess)
    XCTAssertFalse(repo.git(["merge", "-q", "side"]).isSuccess, "前提: a.txt が競合する")
    try repo.write("b.txt", "edited\n")
    show(until: { $0.changes.changes.count == 2 }, "競合と変更の行")
    let header = try XCTUnwrap(panel.layout.index[ScmRowID(section: .changes, path: nil)])

    var discarding: [String] = []
    panel.onDiscard = { files in discarding += files.map(\.path) }
    panel.press(header, .discardAll)
    XCTAssertEqual(discarding, ["b.txt"])

    panel.press(header, .stageAll)
    idle("すべてステージ")
    pumpMain(until: { self.panel.changes.staged.map(\.path) == ["b.txt"] }, "b.txt だけがステージ済みへ")
    XCTAssertEqual(
      repo.git(["diff", "--name-only", "--diff-filter=U"]).stdoutText, "a.txt\n", "競合のまま")
  }
}

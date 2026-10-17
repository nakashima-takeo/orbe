import OrbeTestSupport
import XCTest

@testable import Orbe

/// 面ごとのソース管理パネル（実 git）: HEAD が push 済みかの追従（隠れていた間の push を含む）・選んだ行が区分から消えた
/// ときの選び直し・一括操作と競合・コミットの中身。
///
/// 壊れると何が起きるか。端末で push したコミットを amend・取り消しで書き換えられる（force push を持たないので Orbe の中では
/// 戻せない）。ステージした行の選択が消えて ↑↓ で見て回る位置を失う・選び直しで diff が勝手に開く。「すべてステージ」が
/// 競合の印の残ったファイルを解決済みにする・「すべて破棄」が競合中のファイルを捨てる。ステージした分だけをコミットした
/// つもりで作業中の変更まで入る・ステージせずに押したコミットに変更が入らない。
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
  func show(until ready: @escaping (ScmPanel) -> Bool, _ message: String) {
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

  /// 隠れている間に根のサービスが離され、その間に端末で push していても、出し直した直後（握り直したサービスが git 管理下と
  /// 分かる前）から amend と取り消しは押せない。
  func testAHeadPushedWhileThePanelWasHiddenCannotBeRewrittenRightAfterItReappears() throws {
    repo.addOrigin()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "local"]).isSuccess)
    show(until: { $0.commitState.canUndo }, "未 push の HEAD は取り消せる")

    panel.isShown = false
    panel.isLive = false
    XCTAssertTrue(repo.git(["push", "-q", "origin", "feat"]).isSuccess)
    panel.isLive = true
    panel.isShown = true
    XCTAssertFalse(panel.commitState.canUndo, "読み直すまでは分からないとして押せない")
    pumpMain(until: { self.panel.isHeadPushed == true }, "push 済みと読む")
    XCTAssertFalse(panel.commitState.canUndo)
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

  /// コミットの中身は押した時点の姿で決まる——ステージ済みがあればそれだけ、無ければ「変更」の全部（変更・削除・未追跡）。
  func testCommitTakesTheStagedPartOrElseEveryChange() throws {
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "b"]).isSuccess)
    try repo.write("a.txt", "edited\n")
    try FileManager.default.removeItem(atPath: repo.root + "/b.txt")
    try repo.write("n.txt", "new\n")
    try repo.write("s.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "s.txt"]).isSuccess)
    show(until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 3 }, "両方の区分")

    panel.control.message = "staged"
    panel.commit()
    idle("ステージ済みのコミット")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "s.txt\n")

    pumpMain(
      until: { self.panel.changes.staged.isEmpty && self.panel.changes.changes.count == 3 },
      "ステージ済みが無くなる")
    panel.control.message = "all"
    panel.commit()
    idle("全部のコミット")
    XCTAssertEqual(
      repo.git(["show", "--name-status", "--format=", "HEAD"]).stdoutText,
      "M\ta.txt\nD\tb.txt\nA\tn.txt\n")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, "")
  }

  /// amend もコミットと同じ範囲で直前のコミットを差し替える——ステージ済みがあればそれだけ、無ければ「変更」の全部。
  func testAmendTakesTheStagedPartOrElseEveryChange() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("s.txt", "staged\n")
    XCTAssertTrue(repo.git(["add", "s.txt"]).isSuccess)
    show(until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 1 }, "両方の区分")
    let commits = repo.git(["rev-list", "--count", "HEAD"]).stdoutText

    panel.amend()
    idle("ステージ済みの amend")
    XCTAssertEqual(repo.git(["rev-list", "--count", "HEAD"]).stdoutText, commits, "積まずに差し替える")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n", "作業中の変更は残る")

    try repo.write("n.txt", "new\n")
    pumpMain(
      until: { self.panel.changes.staged.isEmpty && self.panel.changes.changes.count == 2 },
      "ステージ済みが無くなる")
    panel.amend()
    idle("全部の amend")
    XCTAssertEqual(repo.git(["rev-list", "--count", "HEAD"]).stdoutText, commits)
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, "")
    XCTAssertEqual(
      repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\nn.txt\ns.txt\n")
  }

  /// 大きな変更（数千件）のある worktree でも、行と件数は最新の status に追いつく——行の組み立てより先にグラフの読み
  /// （コミットのたびに git の状態が変わって起きる）が返っても、手元の古い行で組み直した結果が最新の status を退けない。
  func testRowsCatchUpWithTheLatestStatusOnALargeWorktree() throws {
    let untracked = 5000
    for index in 0..<untracked { try repo.write("u/\(index).txt", "u\n") }
    show(
      until: { $0.changes.changes.count == untracked && $0.count == untracked },
      "初めて出したパネルに全件の行と件数")

    XCTAssertTrue(repo.git(["add", "u/0.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "terminal"]).isSuccess)
    settle(changes: untracked - 1, "端末でコミットした後")

    panel.control.stage([GitStatus.Row(path: "u/1.txt", originalPath: nil)])
    idle("ステージ")
    pumpMain(until: { self.panel.changes.staged.count == 1 }, "u/1.txt がステージ済みへ")
    panel.control.message = "panel"
    panel.control.commit(.staged)
    idle("コミット")
    settle(changes: untracked - 2, "パネルでコミットした後")
  }

  /// HEAD のコミットをグラフが読み終え、行と件数がステージ済み 0・変更 `changes` 件に揃うまで待つ。
  private func settle(changes: Int, _ message: String) {
    pumpMain(
      until: {
        self.panel.graph?.commits.first?.oid == self.repo.head()
          && self.panel.changes.staged.isEmpty && self.panel.changes.changes.count == changes
          && self.panel.count == changes
      }, timeout: 20, message)
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
    panel.press(header, .discardAll, in: panel.layout)
    XCTAssertEqual(discarding, ["b.txt"])

    panel.press(header, .stageAll, in: panel.layout)
    idle("すべてステージ")
    pumpMain(until: { self.panel.changes.staged.map(\.path) == ["b.txt"] }, "b.txt だけがステージ済みへ")
    XCTAssertEqual(
      repo.git(["diff", "--name-only", "--diff-filter=U"]).stdoutText, "a.txt\n", "競合のまま")
  }
}

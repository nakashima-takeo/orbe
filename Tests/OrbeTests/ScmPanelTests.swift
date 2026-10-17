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

  /// ステージ（index だけの変化）の間とその後の読み直しの間も、同じ HEAD なら push 済みかを前の値のまま使う——▾ が押せない
  /// 姿へ点滅しない。
  func testStagingKeepsKnowingWhetherTheHeadIsPushed() throws {
    repo.addOrigin()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "local"]).isSuccess)
    try repo.write("c.txt", "c\n")
    show(until: { $0.isHeadPushed == false && $0.changes.changes.count == 1 }, "未 push の HEAD と変更")

    var unknown = 0
    panel.control.stage([GitStatus.Row(path: "c.txt", originalPath: nil)])
    let settled = Date().addingTimeInterval(1.5)
    pumpMain(
      until: {
        if self.panel.isHeadPushed == nil { unknown += 1 }
        return self.panel.control.operations.isEmpty && Date() > settled
      }, "ステージと、index の変化の後の読み直し")
    XCTAssertEqual(unknown, 0)
    XCTAssertEqual(panel.changes.staged.map(\.path), ["c.txt"])
  }

  /// 自分のコミットの後、新しい HEAD を読み終えたら、その後に届くコミットの ref の変化（HEAD・ローカルのブランチ）では
  /// push 済みかを分からないに戻さない——remote 追跡 ref が動いていなければ、同じ HEAD の push 済みは変わらない。
  func testOwnCommitDoesNotMakeThePushStateUnknownAgain() throws {
    repo.addOrigin()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    show(until: { $0.isHeadPushed == true && $0.changes.changes.count == 1 }, "push 済みの HEAD と変更")

    panel.control.message = "local"
    panel.commit()
    idle("コミット")
    let head = repo.head()
    pumpMain(until: { self.panel.isHeadPushed == false }, "新しい HEAD は未 push と読む")
    XCTAssertEqual(panel.branch?.commit, head)
    var unknown = 0
    let settled = Date().addingTimeInterval(1.5)
    pumpMain(
      until: {
        if self.panel.isHeadPushed == nil { unknown += 1 }
        return Date() > settled
      }, "コミットの ref の変化が監視から届いた後")
    XCTAssertEqual(unknown, 0)
    XCTAssertTrue(panel.commitState.canUndo)

    XCTAssertTrue(repo.git(["push", "-q", "origin", "feat"]).isSuccess)
    pumpMain(until: { !self.panel.commitState.canUndo }, "端末で push した後は取り消せない")
    XCTAssertFalse(panel.commitState.canAmend)
  }

  /// 自分の push が終わったその時点から、読み直し終わるまで amend と取り消しは押せない（push は HEAD を動かさないので、前の
  /// 「未 push」を残すと push したコミットを書き換えられる）。
  func testRightAfterItsOwnPushTheHeadCannotBeRewritten() throws {
    repo.addOrigin()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("b.txt", "b\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "local"]).isSuccess)
    show(until: { $0.commitState.canUndo }, "未 push の HEAD は取り消せる")

    panel.control.publish()
    pumpMain(until: { self.panel.control.operations.isEmpty }, timeout: 20, "公開")
    XCTAssertNil(panel.control.failure)
    XCTAssertFalse(panel.commitState.canUndo, "push の終わりの時点で前の値を使わない")
    pumpMain(until: { self.panel.isHeadPushed == true }, "push 済みと読む")
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

  /// ステージ済みが 0 のときに行の ＋ を押し、そのステージが終わる前にコミットしても、押した行だけをコミットする（走っている・
  /// 順番を待つステージは済んだものとして数える）。
  func testCommittingRightAfterAStageTakesOnlyTheStagedRow() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("n.txt", "new\n")
    show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "変更の行")

    panel.control.stage([GitStatus.Row(path: "n.txt", originalPath: nil)])
    panel.control.message = "only n"
    panel.commit()
    idle("ステージとコミット")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "n.txt\n")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n")
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

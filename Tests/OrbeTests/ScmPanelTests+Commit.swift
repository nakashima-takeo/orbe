import XCTest

@testable import Orbe

/// コミット・amend・コミットしてプッシュの中身（実 git）——押した時点の範囲で、ステージ済みがあればそれだけ、無ければ
/// 「変更」の全部。行の組み直しが status より遅れて当たる間に押しても、見えていなかった変更は入らない。
///
/// 壊れると何が起きるか。ステージした分だけをコミットしたつもりで、作業中の変更や未追跡（秘密のファイルを含みうる）まで
/// 入り、コミットしてプッシュなら remote にも届く。ステージせずに押したコミットに変更が入らない。
extension ScmPanelTests {
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

  /// ステージが終わってから行の組み直しが当たるまでの間（status はもうステージ後の姿で、行はまだ「変更」のまま）に押しても、
  /// コミット・amend・コミットしてプッシュは押した行だけを入れ、押していない変更と未追跡を入れない。
  func testCommittingBeforeTheRowsCatchUpWithAStageTakesOnlyTheStagedRow() throws {
    let actions: [(String, (ScmPanel) -> Void)] = [
      ("commit", { $0.commit() }), ("amend", { $0.amend() }),
      ("commitAndPush", { $0.commitAndPush() }),
    ]
    for (name, act) in actions {
      if name != actions[0].0 {
        panel.isShown = false
        panel.isLive = false
        repo = try TempGitRepo()
      }
      if name == "commitAndPush" { repo.addOrigin() }
      try repo.write("a.txt", "edited\n")
      try repo.write("n.txt", "new\n")
      try repo.write("secret.env", "token\n")
      show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 3 }, "\(name): 変更の行")
      panel.control.message = "only n"
      var observed: (staged: Int, isStaging: Bool)?
      let hook = FinishHook(.stage) { [panel] in
        guard let panel else { return }
        observed = (panel.changes.staged.count, panel.control.isStaging)
        act(panel)
      }
      panel.control.addObserver(hook)
      withExtendedLifetime(hook) {
        panel.control.stage([GitStatus.Row(path: "n.txt", originalPath: nil)])
        pumpMain(until: { observed != nil }, "\(name): ステージが終わる")
        idle("\(name): コミット")
      }
      XCTAssertNil(panel.control.failure, name)
      XCTAssertEqual(observed?.staged, 0, "\(name): 前提: 行はまだ組み直されていない")
      XCTAssertEqual(observed?.isStaging, false, "\(name): 前提: ステージは列から外れている")
      XCTAssertEqual(
        repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n?? secret.env\n", name)
      XCTAssertTrue(
        repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText.contains("n.txt"), name)
    }
  }

  /// 最後のステージ済みを解除し終えてから行の組み直しが当たるまでの間（status はもうステージ済み無しで、行はまだステージ
  /// 済みを見せている）に押しても、コミット・amend・コミットしてプッシュは「変更」に見えていた変更と未追跡を入れない。
  func testCommittingBeforeTheRowsCatchUpWithTheLastUnstageTakesNothingThatWasNotStaged() throws {
    let actions: [(String, (ScmPanel) -> Void)] = [
      ("commit", { $0.commit() }), ("amend", { $0.amend() }),
      ("commitAndPush", { $0.commitAndPush() }),
    ]
    for (name, act) in actions {
      if name != actions[0].0 {
        panel.isShown = false
        panel.isLive = false
        repo = try TempGitRepo()
      }
      if name == "commitAndPush" { repo.addOrigin() }
      try repo.write("a.txt", "edited\n")
      try repo.write("n.txt", "new\n")
      try repo.write("secret.env", "token\n")
      XCTAssertTrue(repo.git(["add", "n.txt"]).isSuccess)
      show(
        until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 2 },
        "\(name): 両方の区分")
      let tree = repo.git(["rev-parse", "HEAD^{tree}"]).stdoutText
      panel.control.message = "only staged"
      var observed: (staged: Int, statusHasStaged: Bool?)?
      let hook = FinishHook(.unstage) { [panel] in
        guard let panel else { return }
        observed = (panel.changes.staged.count, panel.liveFiles?.status?.hasStagedChanges)
        act(panel)
      }
      panel.control.addObserver(hook)
      withExtendedLifetime(hook) {
        panel.control.unstage([GitStatus.Row(path: "n.txt", originalPath: nil)])
        pumpMain(until: { observed != nil }, "\(name): 解除が終わる")
        idle("\(name): コミット")
      }
      XCTAssertEqual(observed?.staged, 1, "\(name): 前提: 行はまだ組み直されていない")
      XCTAssertEqual(observed?.statusHasStaged, false, "\(name): 前提: status はもう解除の後")
      XCTAssertEqual(repo.git(["rev-parse", "HEAD^{tree}"]).stdoutText, tree, name)
      XCTAssertEqual(
        repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n?? n.txt\n?? secret.env\n", name)
    }
  }

  /// 面を出し直して最初の status が届く前（新しく握った根のサービスが git dir を解き、status はまだ無い）に押しても、
  /// 見えていたステージ済みだけをコミットする。
  func testCommittingBeforeTheFirstStatusAfterReappearingTakesOnlyTheStagedRows() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("n.txt", "new\n")
    try repo.write("secret.env", "token\n")
    XCTAssertTrue(repo.git(["add", "n.txt"]).isSuccess)
    show(until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 2 }, "両方の区分")

    panel.isShown = false
    panel.isLive = false
    panel.isLive = true
    panel.isShown = true
    pumpMain(until: { self.panel.liveFiles?.repo != nil }, "握り直した根のサービスが git dir を解く")
    XCTAssertNil(panel.liveFiles?.status, "前提: 最初の status はまだ届いていない")
    panel.control.message = "only n"
    panel.commit()
    idle("コミット")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "n.txt\n")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n?? secret.env\n")
  }
}

/// `kind` の操作が終わった知らせの中で 1 回だけ `body` を呼ぶ。
@MainActor
private final class FinishHook: SourceControlObserver {
  private let kind: SourceControl.Kind
  private var body: (() -> Void)?

  init(_ kind: SourceControl.Kind, _ body: @escaping () -> Void) {
    self.kind = kind
    self.body = body
  }

  func sourceControl(_ control: SourceControl, operationDidFinish kind: SourceControl.Kind) {
    guard kind == self.kind, let body else { return }
    self.body = nil
    body()
  }
}

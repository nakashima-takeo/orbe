import XCTest

@testable import Orbe

/// コミット・amend・コミットしてプッシュの中身（実 git）——押した時点に見えている範囲で、ステージ済みがあればそれだけ、
/// 無ければ「変更」の全部。行の組み直しが status より遅れて当たる間や、外の書き込みがまだ行に出ていない間に押すと、
/// 何も書かずに断る。
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

  /// ステージ済みが 0 のときに行の ＋ を押し、そのステージが終わる前にコミットすると、何も書かずに断る（見えていなかった
  /// ステージ済みが index にある）。行が追いついてから押し直せば、押した行だけが入る。
  func testCommittingRightAfterAStageIsRefusedUntilTheRowsCatchUp() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("n.txt", "new\n")
    show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "変更の行")
    let head = repo.head()

    panel.control.stage([GitStatus.Row(path: "n.txt", originalPath: nil)])
    panel.control.message = "only n"
    panel.commit()
    idle("ステージとコミット")
    XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch))
    XCTAssertEqual(repo.head(), head)
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\nA  n.txt\n")

    pumpMain(until: { self.panel.changes.staged.count == 1 }, "行が追いつく")
    panel.commit()
    idle("押し直したコミット")
    XCTAssertNil(panel.control.failure)
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "n.txt\n")
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n")
  }

  /// 行の組み直しが status に追いつく前に押したコミット・amend・コミットしてプッシュは、どれも何も書かずに断る——ステージ
  /// の直後（行は「変更」のまま）でも、最後のステージ済みの解除の直後（行はステージ済みを見せたまま）でも。
  func testCommittingBeforeTheRowsCatchUpIsRefusedAndWritesNothing() throws {
    let n = GitStatus.Row(path: "n.txt", originalPath: nil)
    let actions: [(String, (ScmPanel) -> Void)] = [
      ("commit", { $0.commit() }), ("amend", { $0.amend() }),
      ("commitAndPush", { $0.commitAndPush() }),
    ]
    for staged in [false, true] {
      let (scene, kind) = staged ? ("解除の直後", SourceControl.Kind.unstage) : ("ステージの直後", .stage)
      for (action, act) in actions {
        let name = "\(scene) \(action)"
        if panel != nil {
          panel.isShown = false
          panel.isLive = false
          repo = try TempGitRepo()
        }
        if action == "commitAndPush" { repo.addOrigin() }
        try repo.write("a.txt", "edited\n")
        try repo.write("n.txt", "new\n")
        try repo.write("secret.env", "token\n")
        if staged { XCTAssertTrue(repo.git(["add", "n.txt"]).isSuccess) }
        show(
          until: { $0.changes.staged.count == (staged ? 1 : 0) && $0.changes.changes.count >= 2 },
          "\(name): 行")
        let head = repo.head()
        panel.control.message = "m"
        var observed: Int?
        let hook = FinishHook(kind) { [panel] in
          guard let panel else { return }
          observed = panel.changes.staged.count
          act(panel)
        }
        panel.control.addObserver(hook)
        withExtendedLifetime(hook) {
          if staged { panel.control.unstage([n]) } else { panel.control.stage([n]) }
          pumpMain(until: { observed != nil }, "\(name): 書き込みが終わる")
          idle("\(name): コミット")
        }
        XCTAssertEqual(observed, staged ? 1 : 0, "\(name): 前提: 行はまだ組み直されていない")
        XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch), name)
        XCTAssertEqual(repo.head(), head, name)
        XCTAssertEqual(
          repo.git(["status", "--porcelain"]).stdoutText,
          staged ? " M a.txt\n?? n.txt\n?? secret.env\n" : " M a.txt\nA  n.txt\n?? secret.env\n",
          name)
      }
    }
  }

  /// 面を出し直して最初の status が届く前（新しく握った根のサービスが git dir を解き、status はまだ無い）に押すと、見えて
  /// いたステージ済みだけをコミットする。隠している間に外でステージされていれば、何も書かずに断る。
  func testCommittingBeforeTheFirstStatusAfterReappearingTakesOnlyWhatWasShown() throws {
    for stagedOutside in [false, true] {
      let name = stagedOutside ? "外でステージされた" : "そのまま"
      if stagedOutside {
        panel.isShown = false
        panel.isLive = false
        repo = try TempGitRepo()
      }
      try repo.write("a.txt", "edited\n")
      try repo.write("n.txt", "new\n")
      try repo.write("secret.env", "token\n")
      XCTAssertTrue(repo.git(["add", "n.txt"]).isSuccess)
      show(
        until: { $0.changes.staged.count == 1 && $0.changes.changes.count == 2 }, "\(name): 両方の区分")
      let head = repo.head()

      panel.isShown = false
      panel.isLive = false
      if stagedOutside { XCTAssertTrue(repo.git(["add", "secret.env"]).isSuccess) }
      panel.isLive = true
      panel.isShown = true
      pumpMain(until: { self.panel.liveFiles?.repo != nil }, "\(name): 握り直した根のサービスが git dir を解く")
      XCTAssertNil(panel.liveFiles?.status, "\(name): 前提: 最初の status はまだ届いていない")
      panel.control.message = "only n"
      panel.commit()
      idle("\(name): コミット")
      if stagedOutside {
        XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch))
        XCTAssertEqual(repo.head(), head)
        XCTAssertEqual(
          repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\nA  n.txt\nA  secret.env\n")
      } else {
        XCTAssertNil(panel.control.failure)
        XCTAssertEqual(
          repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "n.txt\n")
        XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, " M a.txt\n?? secret.env\n")
      }
    }
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

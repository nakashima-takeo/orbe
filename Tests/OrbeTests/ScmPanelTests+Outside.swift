import XCTest

@testable import Orbe

/// 自分が押していない変化（端末での `git add`・外でのコミット）とコミット・amend・コミットしてプッシュ・取り消し（実 git）
/// ——変化がまだ行に出ていない間に押す、または ▾ を開いた後に変化があると、何も書かずに断る。
///
/// 壊れると何が起きるか。端末やエージェントがステージしたファイル（秘密のファイルを含みうる）や見えていないコミットの上に
/// コミットが重なり、コミットしてプッシュなら remote にも届く。見えていないコミットを amend で書き換え、取り消しで外す。
extension ScmPanelTests {
  /// 自分が押していない変化——端末での `git add` の直後（監視が届いて行に出る前）に押したコミット・amend・コミットして
  /// プッシュは、何も書かずに断る。
  func testCommittingRightAfterAnOutsideChangeIsRefusedAndWritesNothing() throws {
    let actions: [(String, (ScmPanel) -> Void)] = [
      ("commit", { $0.commitSnapshot().commit() }), ("amend", { $0.commitSnapshot().amend() }),
      ("commitAndPush", { $0.commitSnapshot().commitAndPush() }),
    ]
    for (name, act) in actions {
      try freshRepo(addingOrigin: name == "commitAndPush")
      try repo.write("a.txt", "edited\n")
      try repo.write("secret.env", "token\n")
      show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "\(name): 行")
      panel.control.message = "m"
      XCTAssertTrue(repo.git(["add", "secret.env"]).isSuccess)
      let (head, status) = (repo.head(), repo.git(["status", "--porcelain"]).stdoutText)
      act(panel)
      idle("\(name): コミット")
      XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch), name)
      XCTAssertEqual(repo.head(), head, name)
      XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, status, name)
    }
  }

  /// 外の `git add` で断られたコミットを、行が追いつく前（断った知らせの中）に押し直しても、また何も書かずに断る——何も
  /// 書かずに断ったコミットは、先にステージする行を書いたことにならない。先のステージの後で hook に拒まれたコミットの
  /// 押し直しは、自分のステージを数えて通る。
  func testPressingAgainRightAfterARefusedCommitIsRefusedToo() throws {
    let actions: [(SourceControl.Kind, (ScmPanel) -> Void)] = [
      (.commit, { $0.commitSnapshot().commit() }), (.amend, { $0.commitSnapshot().amend() }),
      (.commitAndPush, { $0.commitSnapshot().commitAndPush() }),
    ]
    for (kind, act) in actions {
      let name = "\(kind)"
      try freshRepo(addingOrigin: kind == .commitAndPush)
      try repo.write("a.txt", "edited\n")
      try repo.write("secret.env", "token\n")
      show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "\(name): 行")
      panel.control.message = "m"
      XCTAssertTrue(repo.git(["add", "secret.env"]).isSuccess)
      let (head, status) = (repo.head(), repo.git(["status", "--porcelain"]).stdoutText)
      var rowsWereBehind = false
      pressRightAfter(
        kind, name, first: act,
        then: {
          rowsWereBehind = $0.changes.staged.isEmpty
          act($0)
        })
      XCTAssertTrue(rowsWereBehind, "\(name): 前提: 行は外のステージにまだ追いついていない")
      XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch), name)
      XCTAssertEqual(repo.head(), head, name)
      XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, status, name)
    }

    try freshRepo(addingOrigin: false)
    try repo.write("a.txt", "edited\n")
    try repo.write(".git/hooks/pre-commit", "#!/bin/sh\n[ -e .git/allow ]\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: repo.root + "/.git/hooks/pre-commit")
    show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 1 }, "hook: 行")
    panel.control.message = "m"
    let repo = self.repo!
    pressRightAfter(
      .commit, "hook", first: { $0.commitSnapshot().commit() },
      then: {
        XCTAssertTrue(
          FileManager.default.createFile(atPath: repo.root + "/.git/allow", contents: nil))
        $0.commitSnapshot().commit()
      })
    XCTAssertNil(panel.control.failure, "自分のステージを数えて通る")
    XCTAssertEqual(repo.git(["show", "--name-only", "--format=", "HEAD"]).stdoutText, "a.txt\n")
  }

  /// 外でのコミット（HEAD が進んだ）が行に出る前に押したコミットは、何も書かずに断る——見えていないコミットの上に重ねない。
  func testCommittingRightAfterAnOutsideCommitIsRefusedAndWritesNothing() throws {
    try repo.write("a.txt", "edited\n")
    try repo.write("z.txt", "agent\n")
    show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "行")
    panel.control.message = "m"
    XCTAssertTrue(repo.git(["add", "z.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "agent"]).isSuccess)
    let (head, status) = (repo.head(), repo.git(["status", "--porcelain"]).stdoutText)

    panel.commitSnapshot().commit()
    idle("コミット")
    XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch))
    XCTAssertEqual(repo.head(), head)
    XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, status)
  }

  /// ▾ を開いている間に外でコミットされ、行がそれに追いついてから選んだ amend・コミットしてプッシュ・取り消しも、何も
  /// 書かずに断る——選んだのは開いた時点の姿で、開いている間の外のコミットは見えていない。
  func testMenuItemsChosenAfterAnOutsideCommitWhileTheMenuIsOpenAreRefused() throws {
    let actions: [(String, (ScmCommitSnapshot) -> Void)] = [
      ("amend", { $0.amend() }), ("commitAndPush", { $0.commitAndPush() }),
      ("undo", { $0.undoLastCommit() }),
    ]
    for (name, act) in actions {
      try freshRepo(addingOrigin: name == "commitAndPush")
      try repo.write("a.txt", "edited\n")
      try repo.write("z.txt", "agent\n")
      show(until: { $0.changes.staged.isEmpty && $0.changes.changes.count == 2 }, "\(name): 行")
      panel.control.message = "m"
      let menu = panel.commitSnapshot()
      XCTAssertTrue(repo.git(["add", "z.txt"]).isSuccess)
      XCTAssertTrue(repo.git(["commit", "-qm", "agent"]).isSuccess)
      let (head, status) = (repo.head(), repo.git(["status", "--porcelain"]).stdoutText)
      pumpMain(
        until: { self.panel.changes.head == head && self.panel.changes.changes.count == 1 },
        "\(name): 行が外のコミットに追いつく")
      act(menu)
      idle("\(name): 書き込み")
      XCTAssertEqual(panel.control.failure?.cause, .git(.contentMismatch), name)
      XCTAssertEqual(repo.head(), head, name)
      XCTAssertEqual(repo.git(["status", "--porcelain"]).stdoutText, status, name)
    }
  }
}

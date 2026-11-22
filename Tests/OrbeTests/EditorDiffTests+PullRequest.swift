import XCTest

@testable import Orbe

/// PR の diff——古い側は PR のマージベースの版（rename なら元のパス）、新しい側は PR の先頭の版。両側とも読むだけで、PR に
/// push があれば新しい両端で作り直す。PR の中身は差し替えの構造体が答える。
///
/// 壊れると何が起きるか: rename したファイルの diff が全部の行の追加になる。PR に push があっても古い diff のまま。手元の
/// 作業ツリーの本文が新しい側に出る。打鍵で PR の diff の本文が変わる。PR が動かしたサブモジュールの diff が出ない。
/// TopBar の現在地が PR の diff でなく作業ツリーのファイルの姿になる。
extension EditorDiffTests {
  /// 差し替えの構造体が返す中身（テストが書き換えて、次の読み直しに答えさせる）。
  private final class Reply {
    var content: GitHubPullRequestContent?
    /// 中身を問い合わせた回数。
    var requests = 0
  }

  private func content(base: String, head: String, number: Int = 5) -> GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: "PR_1", number: number, title: "題", url: "https://github.com/me/r/pull/\(number)",
      isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: head, commitCount: 1, commits: [],
      files: [.init(path: "b.txt", change: .renamed, isViewed: false)])
  }

  /// PR の画面を出した窓のタブ（PR の diff を本体に出す）。
  private func pullRequestTab() -> (TerminalTab, NSWindow) {
    let hosted = tab()
    hosted.0.group.editor.selectScreen(.pullRequest)
    return hosted
  }

  /// `reply` の中身を答える PR の状態を作り、手元のリポジトリを結ぶ。
  private func pullRequest(_ reply: Reply, number: Int = 5) throws -> PullRequestState {
    let state = PullRequestState.shared(
      for: PullRequestState.Key(
        commonDir: repo.root + "/.git",
        id: try XCTUnwrap(GitHubItemID(repo: "me/r", number: number))),
      source: PullRequestSource(
        branchPullRequests: { _, _, _ in }, branchExists: { _, _ in },
        content: { _, completion in
          reply.requests += 1
          completion(reply.content.map { .success($0) } ?? .failure(.reason("")))
        },
        setViewed: { _, _, _, _ in }, review: { _, _ in }, writeReview: { _, _, _, _, _ in }))
    state.attach(repo: try repo.open(), fetchRemote: nil, headRemote: nil)
    return state
  }

  /// rename したファイルは、マージベースの版の元のパスと比べ、両側とも読むだけ。PR に push があって両端が変われば、新しい
  /// 先頭の本文で作り直す。
  func testAPullRequestDiffComparesTheMergeBaseAndFollowsANewHead() throws {
    let base = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    XCTAssertTrue(repo.git(["mv", "a.txt", "b.txt"]).isSuccess)
    try repo.write("b.txt", "one\ntwo\nTHREE\nfour\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "rename and change"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    let reply = Reply()
    reply.content = content(base: base, head: head)
    let state = try pullRequest(reply)
    let (tab, _) = pullRequestTab()

    let diff = try tab.group.editor.openDiff(id("b.txt", .pullRequest(state)))
    XCTAssertEqual(
      tab.group.editorLocation, .pullRequest(number: 5, relative: "b.txt"), "TopBar の現在地は PR の diff"
    )

    waitRows(diff, "元のパスと比べた 1 行の変更") { self.removedLines($0) == [2] }
    XCTAssertNil(diff.document, "新しい側は版の本文で、作業ツリーの文書ではない")
    diff.newSurface?.responder.perform(Selector(("insertText:")), with: "x")
    XCTAssertEqual(diff.newRevision?.text.lineCount, 5, "打鍵で本文が変わらない")

    XCTAssertTrue(repo.git(["switch", "-q", "feat"]).isSuccess)
    try repo.write("b.txt", "one\ntwo\nTHREE\nfour\nfive\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "push"]).isSuccess)
    let pushed = repo.head()
    reply.content = content(base: base, head: pushed)
    state.reload()
    waitRows(diff, "新しい先頭で作り直す") { _ in diff.newRevision?.text.lineCount == 6 }
    XCTAssertEqual(diff.revisionHunks.count, 2, "変えた行と足した行")
  }

  /// 版の本文を読めなかった PR の diff は、PR の中身を読み直すとき（再読込など）にもう一度読み、読めれば diff を出す。
  func testAPullRequestDiffThatFailedToReadARevisionReadsItAgainOnReload() throws {
    try repo.write(".gitattributes", "*.bad filter=bad\n")
    try repo.write("x.bad", "one\n")
    XCTAssertTrue(repo.git(["add", "-A"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "bad"]).isSuccess)
    let base = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("x.bad", "two\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "change"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.bad.smudge", "false"]).isSuccess)
    XCTAssertTrue(repo.git(["config", "filter.bad.required", "true"]).isSuccess)
    let reply = Reply()
    reply.content = content(base: base, head: head)
    let state = try pullRequest(reply)
    let (tab, _) = pullRequestTab()
    let diff = try tab.group.editor.openDiff(id("x.bad", .pullRequest(state)))
    pumpMain(until: { diff.content == .unavailable(.failed) }, "前提: 版の本文を読めない")

    XCTAssertTrue(repo.git(["config", "filter.bad.smudge", "cat"]).isSuccess)
    state.reload()
    waitRows(diff, "読み直して diff を出す") { self.removedLines($0) == [0] }
  }

  /// PR が動かしたサブモジュールは、両側とも「Subproject commit」の 1 行で、その 1 行の差になる。
  func testAPullRequestDiffOfASubmoduleShowsTheSubprojectCommitLines() throws {
    try repo.addSubmodule("sub")
    let commit = {
      self.repo.git(["-C", "sub", "rev-parse", "HEAD"]).stdoutText.trimmingCharacters(in: .newlines)
    }
    let base = repo.head()
    let first = commit()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    XCTAssertTrue(
      repo.git(["-C", "sub", "commit", "-q", "--allow-empty", "-m", "inside"]).isSuccess)
    let second = commit()
    XCTAssertTrue(repo.git(["commit", "-qam", "move sub"]).isSuccess)
    let reply = Reply()
    reply.content = content(base: base, head: repo.head())
    let (tab, _) = pullRequestTab()

    let diff = try tab.group.editor.openDiff(
      id("sub", .pullRequest(try pullRequest(reply))))

    waitRows(diff, "1 行の差") { self.removedLines($0) == [0] }
    XCTAssertEqual(text(diff.old), "Subproject commit \(first)")
    XCTAssertEqual(text(diff.newRevision), "Subproject commit \(second)")
  }

  /// 表示できない PR の diff は、PR の種類の理由の一文を出す——両側とも無いパスと、手元に揃わない PR のコミット。
  func testAPullRequestDiffThatCannotBeShownSaysWhy() throws {
    let (tab, _) = pullRequestTab()
    let pane = tab.group.view.editor
    let reply = Reply()
    reply.content = content(base: repo.head(), head: repo.head())
    let nowhere = try tab.group.editor.openDiff(
      id("nope.txt", .pullRequest(try pullRequest(reply))))
    pumpMain(until: { pane.faceContent == .notice(.editorDiffNowherePullRequest) }, "どちらの側にもない")
    XCTAssertEqual(nowhere.content, .unavailable(.nowhere))

    let missing = Reply()
    missing.content = content(base: repo.head(), head: String(repeating: "0", count: 40), number: 6)
    _ = try tab.group.editor.openDiff(
      id("a.txt", .pullRequest(try pullRequest(missing, number: 6))))
    pumpMain(
      until: { pane.faceContent == .notice(.editorDiffPullRequestCommitsMissing) }, "コミットを取得できない")
  }

  /// ほかの者が見ている PR の diff を開いても、GitHub に問い直さない（先に読んである中身で出す）。
  func testOpeningAPullRequestDiffThatIsAlreadyWatchedDoesNotAskGitHubAgain() throws {
    let base = repo.head()
    try repo.write("a.txt", "changed\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "change"]).isSuccess)
    let reply = Reply()
    reply.content = content(base: base, head: repo.head())
    let state = try pullRequest(reply)
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    pumpMain(until: { reply.requests == 1 }, "前提: ほかの者が見始めて読んだ")
    let (tab, _) = pullRequestTab()

    let diff = try tab.group.editor.openDiff(id("a.txt", .pullRequest(state)))

    waitRows(diff, "先に読んである中身で出る") { _ in diff.newRevision != nil }
    XCTAssertEqual(reply.requests, 1, "開いても問い直さない")
  }
}

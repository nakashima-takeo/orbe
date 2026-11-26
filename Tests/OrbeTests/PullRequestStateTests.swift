import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR ごとの状態（`PullRequestState`）——中身の読み直し、確認済みの先行反映と書き込みの順序、diff の両端。GitHub は差し替えの
/// 構造体が答え、git は一時リポジトリで実際に問う。
///
/// 壊れると何が起きるか: 読み直しの失敗で前の中身が消える。押した直後の読み直しでチェックが外れる・2 回続けて押したのに
/// 最初の値に戻る・書き込みの失敗でチェックが付いたまま残る。PR に push があっても diff が古い両端のまま、コミットが
/// 手元に無いと diff が出ないまま止まる。
@MainActor
final class PullRequestStateTests: OrbeTestCase {
  var gitHub: PullRequestFakeGitHub!
  var key: PullRequestState.Key!

  override func setUpWithError() throws {
    gitHub = PullRequestFakeGitHub()
    key = PullRequestState.Key(
      commonDir: "/tmp/\(UUID().uuidString)",
      id: try XCTUnwrap(GitHubItemID(repo: "o/r", number: 7)))
  }

  func content(
    viewed: Set<String> = [], base: String = "b", head: String = "h", files: [String] = ["a", "b"]
  ) -> GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: "PR_1", number: 7, title: "題", url: "https://github.com/o/r/pull/7", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: head, commitCount: 0, commits: [],
      files: files.map { .init(path: $0, change: .modified, isViewed: viewed.contains($0)) })
  }

  private func watchedState() -> PullRequestState {
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    return state
  }

  // MARK: - 中身

  /// 見ている者がいる間だけ読み、読み直しの失敗は失敗の文になって、前に読めた中身は残る。
  func testAFailedReloadKeepsTheLastContent() {
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    gitHub.content = .success(content())
    state.reload()
    XCTAssertNil(state.content, "見ている者がいなければ読まない")

    state.beginWatching()
    state.reload()
    XCTAssertEqual(state.content?.title, "題")
    gitHub.content = .failure(.unreachable)
    state.reload()
    XCTAssertEqual(state.content?.title, "題", "前の中身は残る")
    XCTAssertEqual(state.contentFailure, .unreachable)
  }

  /// 読んでいる間に来た読み直しは、終わった後に 1 回だけ読む。
  func testReloadsWhileReadingCollapseIntoOne() {
    let state = watchedState()
    gitHub.answersAtOnce = false
    gitHub.content = .success(content())
    state.reload()
    state.reload()
    state.reload()
    XCTAssertEqual(gitHub.contentRequests.count, 1)
    gitHub.answerContent()
    XCTAssertEqual(gitHub.contentRequests.count, 1, "終わった後の 1 回")
    gitHub.answerContent()
    XCTAssertEqual(gitHub.contentRequests.count, 0, "それより多くは読まない")
  }

  // MARK: - 確認済み

  /// 押した瞬間に付き、通れば GitHub の値として残る。通らなければ元に戻り、失敗の文が出る。
  func testViewedIsShownAtOnceAndRevertsOnFailure() {
    let state = watchedState()
    gitHub.content = .success(content())
    state.reload()

    state.setViewed(true, paths: ["a", "b"])
    XCTAssertTrue(state.isViewed("a"))
    XCTAssertEqual(state.viewedCount.viewed, 2)
    gitHub.finishWrite(written: ["a"], failure: .rateLimited)
    XCTAssertTrue(state.isViewed("a"), "通ったパスは残る")
    XCTAssertFalse(state.isViewed("b"), "通らなかったパスは元に戻る")
    XCTAssertEqual(state.viewedFailure, .rateLimited)
  }

  /// 書き込みより前に出して後から届いた読み直しは、通ったチェックを外さない。書いている途中のパスも上書きしない。
  func testAReloadIssuedBeforeAWriteDoesNotUndoIt() {
    let state = watchedState()
    gitHub.content = .success(content())
    state.reload()
    gitHub.answersAtOnce = false
    state.reload()
    state.setViewed(true, paths: ["a"])
    gitHub.finishWrite()
    gitHub.answerContent()
    XCTAssertTrue(state.isViewed("a"), "書き込みより前に出した読み直しは、通った値を上書きしない")

    gitHub.content = .success(content(viewed: ["a"]))
    state.reload()
    state.setViewed(false, paths: ["a"])
    gitHub.answerContent()
    XCTAssertFalse(state.isViewed("a"), "書いている途中は重ねた値")
    gitHub.finishWrite(written: [], failure: .unreachable)
    XCTAssertTrue(state.isViewed("a"), "通らなければ GitHub の値に戻る")

    gitHub.answersAtOnce = true
    gitHub.content = .success(content())
    state.reload()
    XCTAssertFalse(state.isViewed("a"), "書き込みの後に出した読み直しは、GitHub の値（外れた）で上書きする")
  }

  /// 書き込みは 1 つずつ順に送り、続けて押したら最後の値になる。
  func testWritesGoOneAtATimeAndTheLastValueWins() {
    let state = watchedState()
    gitHub.content = .success(content())
    state.reload()
    state.setViewed(true, paths: ["a"])
    state.setViewed(false, paths: ["a"])
    XCTAssertEqual(gitHub.writes.count, 1, "前の書き込みが終わってから次を送る")
    XCTAssertFalse(state.isViewed("a"))
    gitHub.finishWrite()
    XCTAssertFalse(state.isViewed("a"), "後の書き込みの重ねた値のまま")
    XCTAssertEqual(gitHub.writes.map(\.viewed), [false])
    gitHub.finishWrite()
    XCTAssertFalse(state.isViewed("a"))
  }

  /// 押した後、書き込みが通る前に出した読み直しの答え（GitHub がまだ書き込みを受けていない時点の値）は、通ったチェックを
  /// 外さない。
  func testAReloadIssuedWhileAWriteIsInFlightDoesNotUndoIt() {
    let state = watchedState()
    gitHub.content = .success(content())
    state.reload()
    gitHub.answersAtOnce = false
    state.setViewed(true, paths: ["a"])
    state.reload()
    gitHub.finishWrite()
    gitHub.answerContent()
    XCTAssertTrue(state.isViewed("a"), "最後に押した値が残る")
  }

  /// 順に並んだ書き込みの途中の 1 つが失敗しても、後に押した書き込みは送られ、押した値のまま通る。
  func testAFailedWriteInTheQueueDoesNotDropTheLaterPress() {
    let state = watchedState()
    gitHub.content = .success(content())
    state.reload()
    state.setViewed(true, paths: ["a"])
    state.setViewed(true, paths: ["b"])
    gitHub.finishWrite(written: [], failure: .unreachable)
    XCTAssertFalse(state.isViewed("a"), "失敗したパスは戻る")
    XCTAssertTrue(state.isViewed("b"), "後に押したパスは押した値のまま")
    XCTAssertEqual(gitHub.writes.map(\.paths), [["b"]], "後の書き込みを送る")
    gitHub.finishWrite()
    XCTAssertTrue(state.isViewed("b"))
  }

  /// 書き込みは、見ている者がいなくなっても順に最後まで送られ、結果は状態に入る。
  func testWritesKeepGoingAfterTheWatchersLeave() {
    let state = watchedState()
    gitHub.content = .success(content())
    state.reload()
    state.setViewed(true, paths: ["a"])
    state.setViewed(true, paths: ["b"])
    state.endWatching()
    gitHub.finishWrite()
    XCTAssertEqual(gitHub.writes.map(\.paths), [["b"]], "後の書き込みも送る")
    gitHub.finishWrite()
    XCTAssertTrue(state.isViewed("a") && state.isViewed("b"))
  }

  /// 書き込みが失敗した後に、その間に出した読み直しの答えが届けば、GitHub の値で見せる。
  func testAReloadAnsweredAfterAFailedWriteShowsGitHubsValue() {
    let state = watchedState()
    gitHub.content = .success(content())
    state.reload()
    gitHub.answersAtOnce = false
    state.setViewed(true, paths: ["a"])
    state.reload()
    gitHub.finishWrite(written: [], failure: .unreachable)
    XCTAssertFalse(state.isViewed("a"), "失敗したら戻る")
    gitHub.content = .success(content(viewed: ["a"]))
    gitHub.answerContent()
    XCTAssertTrue(state.isViewed("a"), "GitHub の値（ほかで付いた）")
  }

  // MARK: - diff の両端

  /// 両端はマージベースと PR の先頭で、間の rename の対応も持つ。手元に無いコミットは、PR が置かれたリポジトリを指す
  /// remote から取ってきて求め直す。
  func testBoundsFetchMissingCommitsAndCarryRenames() throws {
    let repo = try TempGitRepo()
    let bare = repo.addOrigin()
    let base = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    XCTAssertTrue(repo.git(["mv", "a.txt", "b.txt"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-qm", "rename"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["push", "-q", "origin", "feat"]).isSuccess)
    let clone = try TempGitRepo(name: "orbe-clone", initialCommit: false)
    XCTAssertTrue(clone.git(["remote", "add", "origin", bare]).isSuccess)
    XCTAssertTrue(clone.git(["fetch", "-q", "origin", "main"]).isSuccess)
    XCTAssertTrue(clone.git(["cat-file", "-e", head + "^{commit}"]).status != 0, "前提: 先頭は手元に無い")

    let state = watchedState()
    gitHub.content = .success(content(base: base, head: head, files: ["b.txt"]))
    state.reload()
    state.attach(repo: try clone.open(), fetchRemote: "origin", headRemote: nil)

    pumpMain(
      until: { if case .ready = state.bounds { return true } else { return false } }, "両端が揃う")
    guard case .ready(_, let ends) = state.bounds else { return XCTFail("両端が揃う") }
    XCTAssertEqual(ends.mergeBase, base)
    XCTAssertEqual(ends.head, head)
    XCTAssertEqual(ends.renames, ["b.txt": "a.txt"])
    XCTAssertTrue(
      clone.git(["for-each-ref", "refs/remotes/origin/feat"]).stdoutText.isEmpty,
      "取ってきても ref は書かない")
  }

  /// 両端を求めている間に見ている者が去れば、手元に無いコミットを取りに行かない。戻れば、読み直しを頼まなくても求め直して
  /// 両端が揃う。
  ///
  /// 取りに行ったかは、origin の upload-pack が呼ばれたかで知る。取りに行く fetch は非同期で、実行しなかったことを観測する口が
  /// 無いので、両端が「求めていない」（`.none`）に戻った後、呼ばれないことを 1 秒見張る。
  func testBoundsAreNotFetchedAfterTheWatchersLeaveAndAreResolvedOnReturn() throws {
    let repo = try TempGitRepo()
    let bare = repo.addOrigin()
    let base = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "pr"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["push", "-q", "origin", "feat"]).isSuccess)
    let clone = try TempGitRepo(name: "orbe-clone", initialCommit: false)
    XCTAssertTrue(clone.git(["remote", "add", "origin", bare]).isSuccess)
    XCTAssertTrue(clone.git(["fetch", "-q", "origin", "main"]).isSuccess)
    let fixture = try GitHangFixture()
    let fetched = fixture.dir.appendingPathComponent("fetched").path
    let uploadPack = try fixture.installScript(
      "upload-pack", body: ": > \"\(fetched)\"\nexec git-upload-pack \"$@\"")
    XCTAssertTrue(clone.git(["config", "remote.origin.uploadpack", uploadPack]).isSuccess)
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    state.beginWatching()
    gitHub.content = .success(content(base: base, head: head))
    state.reload()
    state.attach(repo: try clone.open(), fetchRemote: "origin", headRemote: nil)
    state.endWatching()

    pumpMain(until: { state.bounds == .none }, "求めるのをやめる")
    XCTAssertTrue(holds(for: 1) { !FileManager.default.fileExists(atPath: fetched) }, "取りに行かない")

    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    pumpMain(
      until: { if case .ready = state.bounds { true } else { false } },
      "戻ったら、読み直しを頼まなくても求め直して揃う")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fetched), "前提: 取りに行くと upload-pack が呼ばれる")
  }

  /// 中身を読む間に見ている者が去って両端を求めなかったときも、戻れば、読み直しを頼まなくても求めて揃う。
  func testBoundsAreResolvedOnReturnAfterLeavingWhileTheContentIsRead() throws {
    let repo = try TempGitRepo()
    let base = repo.head()
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "pr"]).isSuccess)
    let state = PullRequestState.shared(for: key, source: gitHub.source)
    state.attach(repo: try repo.open(), fetchRemote: nil, headRemote: nil)
    state.beginWatching()
    gitHub.answersAtOnce = false
    gitHub.content = .success(content(base: base, head: repo.head()))
    state.reload()
    state.endWatching()
    gitHub.answerContent()
    XCTAssertEqual(state.bounds, .none, "前提: 見ている者がいないので求めない")

    state.beginWatching()
    addTeardownBlock { @MainActor in state.endWatching() }
    pumpMain(
      until: { if case .ready = state.bounds { true } else { false } }, "戻ったら求めて揃う")
  }

  /// 浅いクローンで、取ってある範囲より古い所で分かれた PR は、共通のコミットが無いとは言わず、取得できなかったとする。
  func testBoundsBeyondAShallowBoundaryAreCommitsMissingNotUnrelated() throws {
    let repo = try TempGitRepo()
    let bare = repo.addOrigin()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "pr"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "pr"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    XCTAssertTrue(repo.git(["commit", "-q", "--allow-empty", "-m", "main"]).isSuccess)
    let base = repo.head()
    XCTAssertTrue(repo.git(["push", "-q", "origin", "main", "pr"]).isSuccess)
    let shallow = try TempGitRepo(name: "orbe-shallow", initialCommit: false)
    XCTAssertTrue(shallow.git(["remote", "add", "origin", "file://" + bare]).isSuccess)
    XCTAssertTrue(shallow.git(["fetch", "-q", "--depth", "1", "origin", "main", "pr"]).isSuccess)

    let state = watchedState()
    gitHub.content = .success(content(base: base, head: head))
    state.reload()
    state.attach(repo: try shallow.open(), fetchRemote: "origin", headRemote: nil)

    pumpMain(until: { if case .failed = state.bounds { true } else { false } }, "求まらない")
    guard case .failed(_, .commitsMissing) = state.bounds else { return XCTFail("\(state.bounds)") }
  }

  /// 取りに行っても手元に揃わないコミットは、取りに行き続けず、取得できなかったとして理由を持つ。読み直しで求め直す。
  func testBoundsThatStayMissingAfterAFetchFailAndAReloadRetries() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    let state = watchedState()
    gitHub.content = .success(content(base: repo.head(), head: String(repeating: "0", count: 40)))
    state.reload()
    state.attach(repo: try repo.open(), fetchRemote: "origin", headRemote: nil)
    pumpMain(until: { if case .failed = state.bounds { return true } else { return false } })
    XCTAssertEqual(state.bounds.ends?.head, String(repeating: "0", count: 40))
    guard case .failed(_, .commitsMissing) = state.bounds else { return XCTFail("\(state.bounds)") }

    state.reload()
    XCTAssertEqual(state.bounds, .none, "読み直しで、求まらなかった両端を外す")
    pumpMain(until: { state.bounds != .none }, "読み直した中身で求め直す")
  }
}

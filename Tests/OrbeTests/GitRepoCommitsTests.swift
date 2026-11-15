import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR の diff が使う git の読み（マージベース・rename の対応・先行と遅れ・push 先の追跡 ref・ref の値）と、コミットを指定する
/// fetch（`GitRepo.fetch(commits:from:handle:completion:)`）。実 git の一時リポジトリでテストする。remote には、ローカルの
/// bare リポジトリを使う（ネットワークに出ない）。
///
/// 壊れると何が起きるか: PR のコミットを取りに行くたびに利用者のリポジトリへ ref・FETCH_HEAD・タグが増える（端末で
/// FETCH_HEAD を使う手順が別のコミットを指す）。rename されたファイルを元のパスと比べられず、全部の行が追加に見える。
/// 手元とのずれの数が逆になる。未公開のブランチを公開済みと読み、PR の作成のボタンが押せてしまう。
@MainActor
final class GitRepoCommitsTests: OrbeTestCase {
  private var temp: TempGitRepo!
  private var repo: GitRepo!

  override func setUpWithError() throws {
    temp = try TempGitRepo()
    repo = try open(temp.root)
  }

  private func open(_ path: String) throws -> GitRepo {
    var opened: GitRepo?
    GitRepo.open(cwd: path) { opened = $0 }
    XCTAssertTrue(pump { opened != nil })
    return try XCTUnwrap(opened)
  }

  private func commit(_ message: String, writing path: String = "a.txt", in cwd: String? = nil)
    throws -> String
  {
    try temp.write(path, message + "\n", in: cwd)
    XCTAssertTrue(temp.git(["add", "-A"], in: cwd).isSuccess)
    XCTAssertTrue(temp.git(["commit", "-qm", message], in: cwd).isSuccess)
    return temp.git(["rev-parse", "HEAD"], in: cwd).stdoutText.trimmingCharacters(
      in: .whitespacesAndNewlines)
  }

  private func landed<Value>(_ start: (@escaping (Value) -> Void) -> Void) -> Value? {
    var result: Value?
    var landed = false
    start {
      result = $0
      landed = true
    }
    XCTAssertTrue(pump { landed })
    return result
  }

  private func pump(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(20)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
  }

  /// remote に、どのブランチにも無い（`refs/pull/1/head` だけが指す）コミットを置く。そのコミットには remote のタグも付け、
  /// 手元は remote のタグを全部取る設定（`tagOpt=--tags`）にする——この設定が無いと、コミットを指定した fetch は
  /// `--no-tags` を外してもタグを取らず、`--no-tags` が効いているかを確かめられない。
  private func stagePullRequestCommit() throws -> String {
    let bare = temp.addOrigin()
    XCTAssertTrue(temp.git(["config", "remote.origin.tagOpt", "--tags"]).isSuccess)
    let other = temp.dir.path + "-pr"
    XCTAssertTrue(temp.git(["clone", "-q", bare, other]).isSuccess)
    XCTAssertTrue(temp.git(["config", "user.email", "o@example.com"], in: other).isSuccess)
    XCTAssertTrue(temp.git(["config", "user.name", "o"], in: other).isSuccess)
    let pr = try commit("pr", in: other)
    XCTAssertTrue(temp.git(["push", "-q", "origin", "HEAD:refs/pull/1/head"], in: other).isSuccess)
    XCTAssertTrue(temp.git(["tag", "v-pr", pr], in: bare).isSuccess)
    XCTAssertFalse(temp.git(["cat-file", "-e", pr + "^{commit}"]).isSuccess, "前提: 手元に無い")
    return pr
  }

  private func refsAndFetchHead() -> String {
    let refs = temp.git(["for-each-ref", "--format=%(refname) %(objectname)"]).stdoutText
    let fetchHead = FileManager.default.fileExists(atPath: temp.root + "/.git/FETCH_HEAD")
    return refs + "FETCH_HEAD=\(fetchHead)"
  }

  /// コミットを指定した fetch は、そのコミットだけを手元に持ってきて、ref・FETCH_HEAD・タグを 1 つも書かない。
  func testFetchingByCommitWritesNoRef() throws {
    let pr = try stagePullRequestCommit()
    let before = refsAndFetchHead()

    let failure = landed {
      self.repo.fetch(commits: [pr], from: "origin", handle: GitRunner.Handle(), completion: $0)
    }

    XCTAssertEqual(failure, .some(nil))
    XCTAssertTrue(temp.git(["cat-file", "-e", pr + "^{commit}"]).isSuccess, "コミットが手元に在る")
    XCTAssertEqual(refsAndFetchHead(), before, "ref・FETCH_HEAD・タグが変わらない")
  }

  /// コミットを渡さなければ git を起こさずに成功で返り、設定の refspec で ref を書く普通の fetch にならない。
  func testFetchingNoCommitsWritesNothing() throws {
    temp.addOrigin()
    try temp.advanceOrigin(writing: "b.txt", "b\n")
    let before = refsAndFetchHead()

    let failure = landed {
      self.repo.fetch(commits: [], from: "origin", handle: GitRunner.Handle(), completion: $0)
    }

    XCTAssertEqual(failure, .some(nil))
    XCTAssertEqual(refsAndFetchHead(), before, "origin/main が進まない")
  }

  /// remote に無いコミットは取れず、git の理由つきの失敗で返る。
  func testFetchingAnUnknownCommitFails() throws {
    temp.addOrigin()
    let failure = landed {
      self.repo.fetch(
        commits: [String(repeating: "1", count: 40)], from: "origin", handle: GitRunner.Handle(),
        completion: $0)
    }
    guard case .reason(let reason)?? = failure else {
      return XCTFail("失敗の理由が返る: \(String(describing: failure))")
    }
    XCTAssertFalse(reason.isEmpty)
  }

  /// マージベースは共通の祖先。求まらなければ、コミットが手元に無いのか共通の祖先が無いのかを分けて返す。
  func testTheMergeBaseIsTheCommonAncestorOrNothing() throws {
    let base = temp.head()
    XCTAssertTrue(temp.git(["checkout", "-q", "-b", "feat"]).isSuccess)
    let feat = try commit("feat")
    XCTAssertTrue(temp.git(["checkout", "-q", "main"]).isSuccess)
    let main = try commit("main", writing: "b.txt")

    XCTAssertEqual(landed { self.repo.mergeBase(main, feat, completion: $0) }, .found(base))
    XCTAssertEqual(
      landed { self.repo.mergeBase(main, String(repeating: "1", count: 40), completion: $0) },
      .missingCommit, "手元に無いコミット")
    XCTAssertTrue(temp.git(["checkout", "-q", "--orphan", "other"]).isSuccess)
    let other = try commit("other", writing: "c.txt")
    XCTAssertEqual(
      landed { self.repo.mergeBase(main, other, completion: $0) }, .unrelated, "共通の祖先が無い")
  }

  /// rename の対応は新しいパス → 元のパスで、rename でない変更は入らない（rename が無ければ空）。パスは空白や非 ASCII を
  /// 含んでもそのまま読む。
  func testRenamesMapTheNewPathToTheOriginal() throws {
    try temp.write("long.txt", (1...20).map { "line \($0)\n" }.joined())
    try temp.write("other.txt", (1...20).map { "other \($0)\n" }.joined())
    let base = try commit("keep", writing: "keep.txt")
    XCTAssertTrue(temp.git(["mv", "long.txt", "dir ü.txt"]).isSuccess)
    XCTAssertTrue(temp.git(["mv", "other.txt", "moved.txt"]).isSuccess)
    let head = try commit("edit", writing: "keep.txt")
    let edited = try commit("edit again", writing: "keep.txt")

    XCTAssertEqual(
      landed { self.repo.renames(from: base, to: head, completion: $0) },
      .some(["dir ü.txt": "long.txt", "moved.txt": "other.txt"]))
    XCTAssertEqual(
      landed { self.repo.renames(from: head, to: edited, completion: $0) }, .some([:]),
      "rename を含まない範囲では空")
  }

  func testCountsAreAheadAndBehind() throws {
    let base = temp.head()
    let first = try commit("first")
    _ = try commit("second")
    let head = temp.head()

    XCTAssertEqual(
      landed { self.repo.counts(head, against: base, completion: $0) },
      .some(GitCommitCounts(ahead: 2, behind: 0)))
    XCTAssertEqual(
      landed { self.repo.counts(first, against: head, completion: $0) },
      .some(GitCommitCounts(ahead: 0, behind: 1)))
  }

  /// push 先の追跡 ref は、push 先の remote（設定が無ければ origin）とローカル名で決まり、公開するまでは値が無い。
  func testThePushTrackingRefFollowsThePushRemote() throws {
    XCTAssertTrue(temp.git(["branch", "feat"]).isSuccess)
    XCTAssertEqual(
      landed { self.repo.pushTracking(ofBranch: "feat", completion: $0) }, .some(.noDestination),
      "remote が無い")

    temp.addOrigin()
    XCTAssertEqual(
      landed { self.repo.pushTracking(ofBranch: "feat", completion: $0) },
      .some(.ref("refs/remotes/origin/feat", commit: nil)), "未公開")
    XCTAssertTrue(temp.git(["push", "-q", "origin", "feat"]).isSuccess)
    XCTAssertEqual(
      landed { self.repo.pushTracking(ofBranch: "feat", completion: $0) },
      .some(.ref("refs/remotes/origin/feat", commit: temp.head())), "公開済み")

    XCTAssertTrue(temp.git(["config", "branch.feat.pushRemote", "fork"]).isSuccess)
    XCTAssertEqual(
      landed { self.repo.pushTracking(ofBranch: "feat", completion: $0) },
      .some(.ref("refs/remotes/fork/feat", commit: nil)), "push 先の設定")
  }

  /// 指定した ref の値だけが入り、無い ref は入らない（パターンの下の階層の ref も入らない）。
  func testRefValuesHoldOnlyTheNamedRefs() throws {
    XCTAssertTrue(temp.git(["update-ref", "refs/remotes/origin/feat/x", "HEAD"]).isSuccess)
    XCTAssertTrue(temp.git(["update-ref", "refs/remotes/origin/main", "HEAD"]).isSuccess)

    XCTAssertEqual(
      landed {
        self.repo.refValues(
          ["refs/remotes/origin/main", "refs/remotes/origin/feat", "refs/remotes/origin/gone"],
          completion: $0)
      }, .some(["refs/remotes/origin/main": temp.head()]))
  }
}

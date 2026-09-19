import XCTest

@testable import Orbe

/// Dispatch が読む git 一覧（`worktree list`・local / remote の `for-each-ref`）を、実 git の一時リポジトリで
/// **値の中に区切りに使われがちな文字（`|`・改行）を含むとき**に測る。形式文字列と読む位置が食い違っても
/// フィクスチャのテストは緑のままなので、実 git の出力を通して契約を見る。
///
/// ここが破れると、`|` や改行を含むパスの worktree が別のパスとして出る・そこで checkout 中のブランチの
/// upstream と track が他の列の値にすり替わって clean の安全確認が事実と食い違う・author 名が途中で
/// 切れる、が黙って起きる（エラーにはならない）。
final class GitRepoDispatchListingTests: OrbeTestCase {
  private var dir: URL!
  /// 本体 worktree。追加の worktree はその外（`dir` 直下）に並べる。
  private var root: String!
  private var repo: GitRepo!

  override func setUpWithError() throws {
    let created = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-listing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    // git は worktree のパスを realpath で報告する（`/var` → `/private/var`）。
    dir = URL(fileURLWithPath: String(cString: realpath(created.path, nil)))
    root = dir.appendingPathComponent("repo").path
    XCTAssertTrue(gitIn(dir.path, ["init", "-q", "-b", "main", root]).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    try commit("a", in: root)
    repo = try open()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - worktree 一覧

  func testWorktreePathsContainingPipeOrNewlineAreReadWhole() throws {
    let piped = try addWorktree("wt|pipe", branch: "piped")
    let broken = try addWorktree("wt\nnewline", branch: "broken")

    let worktrees = try listWorktrees()

    XCTAssertEqual(
      Set(worktrees.map { "\($0.path) → \($0.branch ?? "-")" }),
      [
        "\(root!) → main", "\(piped) → piped", "\(broken) → broken",
      ])
  }

  // MARK: - local ブランチ

  /// 列がずれると、パスの後ろ半分が upstream として読まれる（clean がそれを事実として判定する）。
  func testBranchCheckedOutUnderPathContainingPipeKeepsItsOwnUpstreamAndTrack() throws {
    XCTAssertTrue(
      git(["remote", "add", "origin", dir.appendingPathComponent("origin.git").path]).isSuccess)
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/side", "main"]).isSuccess)
    let path = try addWorktree("wt|side", branch: "side")
    XCTAssertTrue(gitIn(path, ["branch", "-q", "--set-upstream-to=origin/side"]).isSuccess)
    try commit("b", in: path)

    let side = try XCTUnwrap(try listLocalBranches().first { $0.name == "side" })

    XCTAssertEqual(
      side.upstream,
      GitUpstream(
        short: "origin/side", ref: "refs/remotes/origin/side", remote: "origin",
        remoteRef: "refs/heads/side", track: .counts(ahead: 1, behind: 0)))
  }

  // MARK: - remote ブランチ

  func testRemoteBranchAuthorContainingPipeIsShownWhole() throws {
    XCTAssertTrue(git(["config", "user.name", "Taro|Yamada"]).isSuccess)
    try commit("b", in: root)
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/feat", "HEAD"]).isSuccess)

    let feat = try XCTUnwrap(try listRemoteBranches().first { $0.name == "origin/feat" })

    XCTAssertTrue(
      feat.relativeDate.hasPrefix("Taro|Yamada · "), "author 名全体 · 相対日時: \(feat.relativeDate)")
  }

  /// author 名の末尾の `\r` が行末の LF と 1 文字にまとまると、次の行がその author 名に吸い込まれて消える。
  /// git CLI の commit は末尾の `\r` を落とすので、コミットオブジェクトを直接書いて作る。
  func testRemoteBranchAfterAuthorEndingWithCarriageReturnIsNotSwallowed() throws {
    let tree = git(["rev-parse", "HEAD^{tree}"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let newer = try writeCommit(tree: tree, author: "evil\r", date: 1_700_000_000)
    let older = try writeCommit(tree: tree, author: "t", date: 1_600_000_000)
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/newer", newer]).isSuccess)
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/older", older]).isSuccess)

    let branches = try listRemoteBranches()

    XCTAssertEqual(branches.map(\.name), ["origin/newer", "origin/older"])
    XCTAssertTrue(
      branches[0].relativeDate.hasPrefix("evil\r · "),
      "author 名全体 · 相対日時: \(branches[0].relativeDate)")
  }

  // MARK: - ヘルパ

  private func listWorktrees() throws -> [GitWorktree] {
    try collect { repo.worktrees(completion: $0) }
  }

  private func listLocalBranches() throws -> [GitBranch] {
    try collect { repo.localBranches(completion: $0) }
  }

  private func listRemoteBranches() throws -> [GitBranch] {
    try collect { repo.remoteBranches(completion: $0) }
  }

  private func collect<T>(_ call: (@escaping (T) -> Void) -> Void) throws -> T {
    var value: T?
    let done = expectation(description: "git 一覧")
    call {
      value = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return try XCTUnwrap(value)
  }

  private func open() throws -> GitRepo {
    let opened: GitRepo? = try collect { GitRepo.open(cwd: root, completion: $0) }
    return try XCTUnwrap(opened)
  }

  private func addWorktree(_ name: String, branch: String) throws -> String {
    let path = dir.appendingPathComponent(name).path
    XCTAssertTrue(git(["worktree", "add", "-q", "-b", branch, path, "main"]).isSuccess)
    return path
  }

  private func commit(_ name: String, in cwd: String) throws {
    try name.write(
      toFile: (cwd as NSString).appendingPathComponent("\(name).txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(gitIn(cwd, ["add", "-A"]).isSuccess)
    XCTAssertTrue(gitIn(cwd, ["commit", "-qm", name]).isSuccess)
  }

  /// author 名を git CLI の正規化を通さずに持つコミットを書き、その oid を返す。
  private func writeCommit(tree: String, author: String, date: Int) throws -> String {
    let file = dir.appendingPathComponent("commit-\(UUID().uuidString)").path
    let object =
      "tree \(tree)\n" + "author \(author) <a@example.com> \(date) +0000\n"
      + "committer c <c@example.com> \(date) +0000\n" + "\nm\n"
    try object.write(toFile: file, atomically: true, encoding: .utf8)
    let written = git(["hash-object", "-t", "commit", "-w", file])
    XCTAssertTrue(written.isSuccess)
    return written.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  private func git(_ args: [String]) -> GitRunner.Output {
    gitIn(root, args)
  }

  @discardableResult
  private func gitIn(_ cwd: String, _ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd)
  }
}

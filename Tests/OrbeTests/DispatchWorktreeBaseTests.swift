import XCTest

@testable import Orbe

/// 新規ブランチを切る worktree 作成の**ベースの鮮度と upstream**（`DispatchDataProvider`）。
/// 実 git の一時リポジトリ（bare origin ＋ 2 つの clone）で、提示時に走る `fetch --prune` の着地を
/// 待ってから作ること・`issue/<n>` に upstream が付かないことを固定する。
///
/// 遅い fetch は `remote.origin.uploadpack` を眠るラッパーへ差し替えて作る（ネットワーク不要）。
/// 「待っている」ことは所要時間ではなく**出来上がった HEAD**で測る——待たなければ手元の古い
/// `refs/remotes/origin/*` が base になり、origin の新しい tip とは一致しない。
@MainActor
final class DispatchWorktreeBaseTests: OrbeTestCase {
  private var dir: URL!
  private var local: String!
  private var origin: String!

  /// `main` と `feat` を持つ origin を立て、手元の clone の remote 追跡 ref を**わざと古いまま**にする。
  /// `mine` は手元にだけあるローカルブランチ（ベースを持たない checkout の題材）。
  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-wtbase-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    origin = dir.appendingPathComponent("origin.git").path
    local = dir.appendingPathComponent("local").path
    let other = dir.appendingPathComponent("other").path

    XCTAssertTrue(run(["init", "-q", "--bare", "-b", "main", origin], cwd: dir.path).isSuccess)
    XCTAssertTrue(run(["init", "-q", "-b", "main", local], cwd: dir.path).isSuccess)
    try identify(local)
    try commit("a", in: local)
    XCTAssertTrue(run(["remote", "add", "origin", origin], cwd: local).isSuccess)
    XCTAssertTrue(run(["push", "-q", "-u", "origin", "main"], cwd: local).isSuccess)
    XCTAssertTrue(run(["branch", "mine", "main"], cwd: local).isSuccess)

    XCTAssertTrue(run(["clone", "-q", origin, other], cwd: dir.path).isSuccess)
    try identify(other)
    XCTAssertTrue(run(["checkout", "-q", "-b", "feat"], cwd: other).isSuccess)
    try commit("c1", in: other)
    XCTAssertTrue(run(["push", "-q", "-u", "origin", "feat"], cwd: other).isSuccess)

    // ここまでを手元へ取り込み、`origin/HEAD` を据える（通常の clone と同じ形）。
    XCTAssertTrue(run(["fetch", "-q", "origin"], cwd: local).isSuccess)
    XCTAssertTrue(
      run(
        ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], cwd: local
      ).isSuccess)

    // 以降の origin 側の前進は手元に入らない＝手元の remote 追跡 ref は古い。
    XCTAssertTrue(run(["checkout", "-q", "main"], cwd: other).isSuccess)
    try commit("b", in: other)
    XCTAssertTrue(run(["push", "-q", "origin", "main"], cwd: other).isSuccess)
    XCTAssertTrue(run(["checkout", "-q", "feat"], cwd: other).isSuccess)
    try commit("c2", in: other)
    XCTAssertTrue(run(["push", "-q", "origin", "feat"], cwd: other).isSuccess)
    XCTAssertNotEqual(
      originTip("main"), localRemoteTip("main"), "前提: 手元の origin/main は古い")
    XCTAssertNotEqual(
      originTip("feat"), localRemoteTip("feat"), "前提: 手元の origin/feat は古い")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - fetch の着地を待ってから切る

  /// Issue 新規は `origin/<既定ブランチ>` から切るので、提示時の fetch が着地してから作る。
  func testIssueWorktreeIsCutFromTheFetchedDefaultBranch() throws {
    let (provider, model) = try startWithSlowFetch()
    let path = try resolve(
      provider, .issue(number: 44, existingWorktree: nil, existingBranch: false))
    XCTAssertEqual(head(of: path), originTip("main"), "fetch 後の origin/main が base")
    XCTAssertNotNil(model.classification, "着地を待った以上、分類も出ている")
  }

  /// Remote branch 行も remote ref から新しいローカルブランチを切る経路。
  func testRemoteBranchWorktreeIsCutFromTheFetchedRemoteRef() throws {
    let (provider, _) = try startWithSlowFetch()
    let path = try resolve(provider, .remoteBranch(name: "origin/feat", existingWorktree: nil))
    XCTAssertEqual(head(of: path), originTip("feat"), "fetch 後の origin/feat が base")
  }

  /// PR 行（same-repo）も head ref から切る経路。
  func testPullRequestWorktreeIsCutFromTheFetchedHeadRef() throws {
    let (provider, _) = try startWithSlowFetch()
    let path = try resolve(
      provider,
      .pullRequest(number: 7, headRef: "feat", isCrossRepo: false, existingWorktree: nil))
    XCTAssertEqual(head(of: path), originTip("feat"), "fetch 後の origin/feat が base")
  }

  /// **既存ブランチの checkout はベースを持たないので待たない。** ここが待つと、fetch が長引く
  /// リポジトリで「手元のブランチを開くだけ」が分単位で止まる。
  func testLocalBranchWorktreeDoesNotWaitForTheFetch() throws {
    let (provider, model) = try startWithSlowFetch()
    let path = try resolve(provider, .localBranch(name: "mine", existingWorktree: nil))
    XCTAssertNil(model.classification, "fetch の着地より前に出来ている")
    XCTAssertEqual(head(of: path), oid(["rev-parse", "mine"], cwd: local))
  }

  /// **fetch が失敗しても作成は続く。** 手元の `refs/remotes/origin/*` が最良で、ここで止めると
  /// origin へ到達できない環境で作成そのものが出来なくなる。
  func testCreationContinuesWhenTheFetchFails() throws {
    XCTAssertTrue(
      run(["remote", "set-url", "origin", dir.appendingPathComponent("gone.git").path], cwd: local)
        .isSuccess)
    let (provider, _) = try start()
    let path = try resolve(
      provider, .issue(number: 44, existingWorktree: nil, existingBranch: false))
    XCTAssertEqual(head(of: path), localRemoteTip("main"), "手元の origin/main から続行する")
  }

  // MARK: - upstream

  /// **`issue/<n>` は upstream を持たない。** `origin/<既定>` を追跡すると `git push` が既定ブランチへ
  /// 向かって拒否され（`push.default=simple`）、upstream が既にあるので `push.autoSetupRemote` も
  /// 発動しない。remote ref から起こす他の 2 経路は逆に、同名の remote ブランチを追跡する。
  func testIssueBranchHasNoUpstreamWhileRemoteRefBranchesTrackOrigin() throws {
    // 追跡の指定を省くと既定が効いてしまう設定。契約が環境に左右されないことをここで測る。
    XCTAssertTrue(run(["config", "branch.autoSetupMerge", "always"], cwd: local).isSuccess)
    let (provider, _) = try start()
    _ = try resolve(provider, .issue(number: 44, existingWorktree: nil, existingBranch: false))
    _ = try resolve(provider, .remoteBranch(name: "origin/feat", existingWorktree: nil))

    XCTAssertFalse(
      run(["config", "--get", "branch.issue/44.merge"], cwd: local).isSuccess,
      "issue ブランチに upstream は付かない")
    XCTAssertEqual(oid(["config", "--get", "branch.feat.remote"], cwd: local), "origin")
    XCTAssertEqual(oid(["config", "--get", "branch.feat.merge"], cwd: local), "refs/heads/feat")
  }

  /// remote を持たないリポジトリでも Issue 新規は成功する（`origin/HEAD` が引けず `main` へ落ちる）。
  func testIssueWorktreeWorksWithoutARemote() throws {
    XCTAssertTrue(run(["remote", "remove", "origin"], cwd: local).isSuccess)
    let (provider, _) = try start()
    let path = try resolve(
      provider, .issue(number: 44, existingWorktree: nil, existingBranch: false))
    XCTAssertEqual(head(of: path), oid(["rev-parse", "main"], cwd: local))
  }

  // MARK: - ヘルパ

  private struct CreationFailed: Error {
    let detail: String
  }

  /// provider を起こし、git レーンの着地（worktree 一覧）まで進める。
  private func start() throws -> (DispatchDataProvider, DispatchPaletteModel) {
    let model = DispatchPaletteModel()
    let provider = DispatchDataProvider(
      cwd: local, model: model, localization: LocalizationStore(language: .ja),
      // 作成先を一時ディレクトリの中へ落とす（後始末に乗せる）。
      worktreeTemplate: "{parent}/wt-{slug}")
    provider.load()
    XCTAssertTrue(pump({ !provider.worktrees.isEmpty }), "前提: git レーンは着地している")
    return (provider, model)
  }

  /// `fetch --prune` を数秒かかる状態にしてから provider を起こす。返るのは fetch が未着地の窓に居る
  /// provider——ここで作成を撃たないと「待つかどうか」を測れない。
  private func startWithSlowFetch() throws -> (DispatchDataProvider, DispatchPaletteModel) {
    let wrapper = dir.appendingPathComponent("slow-upload-pack").path
    try "#!/bin/sh\nsleep 2\nexec git-upload-pack \"$@\"\n".write(
      toFile: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
    XCTAssertTrue(run(["config", "remote.origin.uploadpack", wrapper], cwd: local).isSuccess)
    let started = try start()
    XCTAssertNil(started.1.classification, "前提: まだ fetch が着地していない")
    return started
  }

  private func resolve(_ provider: DispatchDataProvider, _ action: DispatchAction) throws -> String
  {
    var resolution: DispatchDataProvider.DirectoryResolution?
    provider.prepareDirectory(for: action) { resolution = $0 }
    XCTAssertTrue(pump({ resolution != nil }, timeout: 30), "作成が返らない")
    guard case .ready(let path) = try XCTUnwrap(resolution) else {
      throw CreationFailed(detail: String(describing: resolution))
    }
    return path
  }

  private func identify(_ repo: String) throws {
    XCTAssertTrue(run(["config", "user.email", "t@example.com"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["config", "user.name", "t"], cwd: repo).isSuccess)
  }

  private func commit(_ name: String, in repo: String) throws {
    try name.write(
      toFile: (repo as NSString).appendingPathComponent("\(name).txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(run(["add", "-A"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["commit", "-qm", name], cwd: repo).isSuccess)
  }

  private func head(of worktree: String) -> String {
    oid(["rev-parse", "HEAD"], cwd: worktree)
  }

  private func originTip(_ branch: String) -> String {
    oid(["rev-parse", branch], cwd: origin)
  }

  private func localRemoteTip(_ branch: String) -> String {
    oid(["rev-parse", "origin/\(branch)"], cwd: local)
  }

  private func oid(_ args: [String], cwd: String) -> String {
    run(args, cwd: cwd).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  private func run(_ args: [String], cwd: String) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd)
  }

  /// main queue を回しながら条件の成立を待つ（provider の completion は main で届く）。
  private func pump(_ condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      usleep(5_000)
    }
    return condition()
  }
}

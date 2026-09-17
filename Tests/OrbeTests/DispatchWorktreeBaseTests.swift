import XCTest

@testable import Orbe

/// 新規ブランチを切る worktree 作成の**upstream**（`DispatchDataProvider`）。
/// 実 git の一時リポジトリ（bare origin ＋ 2 つの clone）で、`issue/<n>` に upstream が付かず、
/// remote ref から起こすブランチは追跡することを固定する。
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

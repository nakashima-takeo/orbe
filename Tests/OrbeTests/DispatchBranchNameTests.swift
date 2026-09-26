import XCTest

@testable import Orbe

/// Dispatch のブランチ行が**ブランチの正確な名前**で出て、Enter がそのブランチの worktree を作ること
/// （`DispatchDataProvider`）。名前に `|` を含むブランチと、同じ名前のタグを持つブランチを、実 git の
/// 一時リポジトリ（bare origin ＋ clone）で git 列挙 → 行 → Enter まで通して測る。
///
/// ここが破れると、`feat|x` の行が消える・`origin/feat|x` の Enter が `origin/feat` から別のブランチを
/// 作る・タグと同名のブランチが worktree で checkout 中なのに Local branches に戻り、Enter すると
/// ブランチではなく detached な worktree ができる——どれもエラーにならず、違うものの上でエージェントが
/// 仕事を始める。
@MainActor
final class DispatchBranchNameTests: OrbeTestCase {
  private var dir: URL!
  private var local: String!
  private var origin: String!
  /// provider が弱参照で持つモデル（行を読むために生かしておく）。
  private var palette: DispatchPaletteModel!

  /// origin に `feat` と `feat|x`（別のコミット）を置き、手元の clone に次のローカルブランチを作る。
  /// `mine|x` は worktree を持たない。`tagged` は同名タグを持ち worktree で checkout 中。`solo` は
  /// 同名タグを持ち worktree を持たない。
  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-branchname-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    origin = dir.appendingPathComponent("origin.git").path
    local = dir.appendingPathComponent("local").path
    let other = dir.appendingPathComponent("other").path

    XCTAssertTrue(run(["init", "-q", "--bare", "-b", "main", origin], cwd: dir.path).isSuccess)
    XCTAssertTrue(run(["clone", "-q", origin, other], cwd: dir.path).isSuccess)
    try identify(other)
    try commit("a", in: other)
    XCTAssertTrue(run(["push", "-q", "origin", "HEAD:main"], cwd: other).isSuccess)
    for branch in ["feat", "feat|x"] {
      XCTAssertTrue(run(["checkout", "-q", "-b", branch, "main"], cwd: other).isSuccess)
      try commit(branch, in: other)
      XCTAssertTrue(run(["push", "-q", "origin", branch], cwd: other).isSuccess)
    }
    XCTAssertNotEqual(originTip("feat"), originTip("feat|x"), "前提: 2 つの remote ブランチは別物")

    XCTAssertTrue(run(["clone", "-q", origin, local], cwd: dir.path).isSuccess)
    for name in ["mine|x", "tagged", "solo"] {
      XCTAssertTrue(run(["branch", name, "main"], cwd: local).isSuccess)
    }
    for name in ["tagged", "solo"] {
      XCTAssertTrue(run(["tag", name, "main"], cwd: local).isSuccess)
    }
    let taggedWorktree = dir.appendingPathComponent("wt-tagged").path
    XCTAssertTrue(run(["worktree", "add", "-q", taggedWorktree, "tagged"], cwd: local).isSuccess)
    XCTAssertEqual(checkedOutRef(at: taggedWorktree), "refs/heads/tagged", "前提: ブランチを checkout 中")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - `|` を含む名前

  func testLocalBranchContainingPipeIsListedWholeAndEnterChecksItOut() throws {
    let provider = try start()
    let item = try XCTUnwrap(row(.localBranch, named: "mine|x"), "Local branches に名前全体で出る")

    let path = try resolve(provider, try XCTUnwrap(item.action))

    XCTAssertEqual(checkedOutRef(at: path), "refs/heads/mine|x")
  }

  /// `origin/feat` が実在するので、名前が `|` で切れると黙ってそちらから `feat` を作る。
  func testRemoteBranchContainingPipeCreatesABranchTrackingItEvenWhenTheShorterNameExists() throws {
    let provider = try start()
    let item = try XCTUnwrap(
      row(.remoteBranch, named: "origin/feat|x"), "Remote branches に名前全体で出る")

    let path = try resolve(provider, try XCTUnwrap(item.action))

    XCTAssertEqual(checkedOutRef(at: path), "refs/heads/feat|x")
    XCTAssertEqual(head(of: path), originTip("feat|x"))
    XCTAssertEqual(
      oid(["rev-parse", "--symbolic-full-name", "feat|x@{upstream}"], cwd: local),
      "refs/remotes/origin/feat|x")
  }

  // MARK: - 同じ名前のタグを持つブランチ

  func testBranchCheckedOutInAWorktreeStaysOutOfLocalBranchesEvenWhenATagSharesItsName() throws {
    _ = try start()

    XCTAssertEqual(localBranchRowNames.filter { $0.hasSuffix("tagged") }, [])
  }

  func testEnterOnABranchSharingATagNameChecksOutTheBranchNotDetached() throws {
    let provider = try start()
    let item = try XCTUnwrap(row(.localBranch, named: "solo"), "Local branches にブランチ名で出る")

    let path = try resolve(provider, try XCTUnwrap(item.action))

    XCTAssertEqual(checkedOutRef(at: path), "refs/heads/solo")
  }

  // MARK: - ヘルパ

  private struct CreationFailed: Error {
    let detail: String
  }

  /// provider を起こし、git レーンの着地（列挙 → 行の組み直し）まで進める。
  private func start() throws -> DispatchDataProvider {
    palette = DispatchPaletteModel()
    let provider = DispatchDataProvider(
      cwd: local, model: palette, localization: LocalizationStore(language: .ja),
      worktreeTemplate: "{parent}/wt-{slug}")
    provider.load()
    XCTAssertTrue(
      pump({
        [.worktree, .localBranch, .remoteBranch].allSatisfy { glyph in
          palette.items.contains { $0.glyph == glyph }
        }
      }), "前提: git レーンは着地している（worktree・Local branch・Remote branch の行が組まれるまで）")
    return provider
  }

  private func row(_ glyph: DispatchItem.Glyph, named name: String) -> DispatchItem? {
    palette.items.first { $0.glyph == glyph && $0.name == name }
  }

  private var localBranchRowNames: [String] {
    palette.items.filter { $0.glyph == .localBranch }.map(\.name)
  }

  private func resolve(_ provider: DispatchDataProvider, _ action: DispatchAction) throws -> String
  {
    guard case .open(let destination) = action else {
      throw CreationFailed(detail: "行き先を持たない行: \(action)")
    }
    var outcome: DispatchDataProvider.DispatchPrepareOutcome?
    provider.prepareDirectory(for: destination) { outcome = $0 }
    XCTAssertTrue(pump({ outcome != nil }, timeout: 30), "解決が返らない")
    guard case .resolved(.ready(let path)) = try XCTUnwrap(outcome) else {
      throw CreationFailed(detail: String(describing: outcome))
    }
    return path
  }

  /// worktree が checkout している ref。detached なら空。
  private func checkedOutRef(at worktree: String) -> String {
    oid(["symbolic-ref", "-q", "HEAD"], cwd: worktree)
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
    oid(["rev-parse", "refs/heads/\(branch)"], cwd: origin)
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

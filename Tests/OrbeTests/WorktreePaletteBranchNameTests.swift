import OrbeTestSupport
import XCTest

@testable import Orbe

/// worktree パレットのブランチ行が**ブランチの正確な名前**で出て、Enter がそのブランチの worktree を作ること
/// （`WorktreePaletteDataProvider`）。名前に `|` を含むブランチと、同じ名前のタグを持つブランチを、実 git の
/// 一時リポジトリ（bare origin ＋ clone）で git 列挙 → 行 → Enter まで通して測る。
///
/// ここが破れると、`feat|x` の行が消える・`origin/feat|x` の Enter が `origin/feat` から別のブランチを
/// 作る・タグと同名のブランチが worktree で checkout 中なのに Local branches に戻り、Enter すると
/// ブランチではなく detached な worktree ができる——どれもエラーにならず、違うものの上でエージェントが
/// 仕事を始める。
@MainActor
final class WorktreePaletteBranchNameTests: OrbeTestCase {
  private var dir: URL!
  private var local: String!
  private var origin: String!
  /// provider が弱参照で持つモデル（行を読むために生かしておく）。
  private var palette: WorktreePaletteModel!

  /// 組（`pair`）の複製を置き、手元の origin を複製の中の `origin.git` へ向け直して、`tagged` を worktree で
  /// checkout する。
  override func setUpWithError() throws {
    dir = TestScratch.caseDir
      .appendingPathComponent("orbe-branchname-\(UUID().uuidString)")
    origin = dir.appendingPathComponent("origin.git").path
    local = dir.appendingPathComponent("local").path
    try Self.pair.copy(to: dir)
    try GitFixtureTemplate.git(["remote", "set-url", "origin", origin], in: local)
    let taggedWorktree = dir.appendingPathComponent("wt-tagged").path
    XCTAssertTrue(run(["worktree", "add", "-q", taggedWorktree, "tagged"], cwd: local).isSuccess)
    XCTAssertEqual(checkedOutRef(at: taggedWorktree), "refs/heads/tagged", "前提: ブランチを checkout 中")
  }

  /// origin に `feat` と `feat|x`（別のコミット）を置き、手元の clone（`local`）に次のローカルブランチを作る。
  /// `mine|x` は worktree を持たない。`tagged` は同名タグを持つ（worktree での checkout は `setUp` が行う）。`solo` は
  /// 同名タグを持ち worktree を持たない。origin を作るための clone（`other`）は残さない。
  private nonisolated(unsafe) static let pair = GitFixtureTemplate(
    name: "orbe-branchname", build: buildPair)

  private nonisolated static func buildPair(_ dir: URL) throws {
    let origin = dir.appendingPathComponent("origin.git").path
    let local = dir.appendingPathComponent("local").path
    let other = dir.appendingPathComponent("other").path
    @discardableResult
    func git(_ args: [String], in cwd: String) throws -> String {
      try GitFixtureTemplate.git(args, in: cwd).stdoutText
    }
    func commit(_ name: String) throws {
      try name.write(
        toFile: (other as NSString).appendingPathComponent("\(name).txt"), atomically: true,
        encoding: .utf8)
      try git(["add", "-A"], in: other)
      try git(["commit", "-qm", name], in: other)
    }

    try git(["init", "-q", "--bare", "-b", "main", origin], in: dir.path)
    try git(["clone", "-q", origin, other], in: dir.path)
    try git(["config", "user.email", "t@example.com"], in: other)
    try git(["config", "user.name", "t"], in: other)
    try commit("a")
    try git(["push", "-q", "origin", "HEAD:main"], in: other)
    for branch in ["feat", "feat|x"] {
      try git(["checkout", "-q", "-b", branch, "main"], in: other)
      try commit(branch)
      try git(["push", "-q", "origin", branch], in: other)
    }
    guard
      try git(["rev-parse", "refs/heads/feat"], in: origin)
        != git(["rev-parse", "refs/heads/feat|x"], in: origin)
    else { throw GitFixtureTemplate.Failure(description: "前提: 2 つの remote ブランチは別物") }

    try git(["clone", "-q", origin, local], in: dir.path)
    for name in ["mine|x", "tagged", "solo"] {
      try git(["branch", name, "main"], in: local)
    }
    for name in ["tagged", "solo"] {
      try git(["tag", name, "main"], in: local)
    }
    try FileManager.default.removeItem(atPath: other)
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
  private func start() throws -> WorktreePaletteDataProvider {
    palette = WorktreePaletteModel()
    let provider = WorktreePaletteDataProvider(
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

  private func row(_ glyph: WorktreePaletteItem.Glyph, named name: String) -> WorktreePaletteItem? {
    palette.items.first { $0.glyph == glyph && $0.name == name }
  }

  private var localBranchRowNames: [String] {
    palette.items.filter { $0.glyph == .localBranch }.map(\.name)
  }

  private func resolve(_ provider: WorktreePaletteDataProvider, _ action: WorktreePaletteAction)
    throws -> String
  {
    guard case .open(let destination) = action else {
      throw CreationFailed(detail: "行き先を持たない行: \(action)")
    }
    var outcome: WorktreeRepoFacts.PrepareOutcome?
    provider.facts.prepareDirectory(for: destination) { outcome = $0 }
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

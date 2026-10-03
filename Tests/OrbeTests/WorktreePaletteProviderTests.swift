import XCTest

@testable import Orbe

/// provider が git の事実から組む、作成行とベースのバーの材料（実 git の一時リポジトリ）。壊れると、
/// git が受け付けない名前に作成行が出る・消えたブランチを「前回」として出す・非 git で ⌘T ↵ が空振りする、
/// のどれかになる。
@MainActor
final class WorktreePaletteProviderTests: OrbeTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    let created = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-wtprovider-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    dir = URL(fileURLWithPath: String(cString: realpath(created.path, nil)))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  /// ブランチ名の有効性は git が答える。古い問いの答えは model が捨てる（今の入力にだけ効く）。
  func testBranchNameValidityComesFromGit() {
    let model = WorktreePaletteModel()
    let provider = WorktreePaletteDataProvider(
      cwd: dir.path, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)
    for (name, expected) in [("feat/x", true), ("bad..name", false), ("trailing.lock", false)] {
      model.query = name
      provider.checkBranchName(name)
      XCTAssertTrue(pump { model.branchNameAnswer?.name == name }, "\(name) に答えが届く")
      XCTAssertEqual(model.branchNameAnswer?.isValid, expected, name)
    }
  }

  /// 非 git の場所は「このディレクトリ」の 1 行だけで、作成行もベースのバーも材料を持たない。
  func testOutsideARepositoryListsOnlyThisDirectory() {
    let model = WorktreePaletteModel()
    let provider = WorktreePaletteDataProvider(
      cwd: dir.path, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)
    provider.load()
    XCTAssertTrue(pump { model.hasLoadedOnce })
    XCTAssertEqual(model.items.map(\.action), [.open(.directory(path: dir.path))])
    XCTAssertNil(model.newBranchRules)
    XCTAssertNil(model.baseFacts)
  }

  /// ベースの事実: 前回は今の列挙にあるときだけ、現在は今の worktree のブランチ。作成行の規則は
  /// ローカルブランチと既存の worktree の作成先を塞ぐ。
  func testBaseFactsAndNewBranchRulesFollowTheRepository() throws {
    let repo = dir.appendingPathComponent("repo").path
    XCTAssertTrue(run(["init", "-q", "-b", "main", repo], cwd: dir.path).isSuccess)
    XCTAssertTrue(run(["config", "user.email", "t@example.com"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["config", "user.name", "t"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["branch", "release"], cwd: repo).isSuccess)
    let template = "\(dir.path)/wt/{slug}"
    XCTAssertTrue(
      run(["worktree", "add", "-q", "-b", "issue/1", "\(dir.path)/wt/issue-1"], cwd: repo)
        .isSuccess)

    func facts(previous: String?) throws -> (WorktreeBaseFacts?, WorktreeNewBranchRules?) {
      let model = WorktreePaletteModel()
      let provider = WorktreePaletteDataProvider(
        cwd: repo, model: model, localization: LocalizationStore(language: .ja),
        worktreeTemplate: template, previousBase: previous)
      provider.load()
      XCTAssertTrue(pump { model.baseFacts != nil && model.newBranchRules != nil })
      return (model.baseFacts, model.newBranchRules)
    }

    let (known, rules) = try facts(previous: "release")
    XCTAssertEqual(known?.previous, "release")
    XCTAssertEqual(known?.current, "main", "今の worktree（cwd）のブランチ")
    XCTAssertEqual(known?.defaultBranch, "main", "origin が無ければ main へ落ちる")
    XCTAssertEqual(try facts(previous: "gone").0?.previous, nil, "列挙に無い前回は出さない")

    let r = try XCTUnwrap(rules)
    XCTAssertFalse(r.allows("release"), "ローカルブランチ")
    XCTAssertFalse(r.allows("issue/1"), "worktree で checkout 中のブランチ")
    XCTAssertFalse(r.allows("issue-1"), "作成先が既存の worktree")
    XCTAssertTrue(r.allows("feat/new"))
  }

  @discardableResult
  private func run(_ args: [String], cwd: String) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd)
  }

  private func pump(_ condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      usleep(5_000)
    }
    return condition()
  }
}

import OrbeTestSupport
import XCTest

@testable import Orbe

/// provider が git の事実から組む、作成行とベースのバーの材料と「今の worktree」（実 git の一時リポジトリ）。
/// 壊れると、git が受け付けない名前や git に拒まれる作成先に作成行が出る・消えたブランチを「前回」として
/// 出す・非 git で ⌘T ↵ が空振りする・⌘T ↵ が今いるのと別の worktree を開く、のどれかになる。
@MainActor
final class WorktreePaletteProviderTests: OrbeTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    let created = TestScratch.caseDir
      .appendingPathComponent("orbe-wtprovider-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    dir = URL(fileURLWithPath: String(cString: realpath(created.path, nil)))
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

  /// git が別のブランチ名へ展開する入力（`@{-1}` など）には作成行を出さない。展開結果の名前で作られ、
  /// 行に出した名前と別のブランチ・worktree ができるため。普通の名前には出る。
  func testInputGitExpandsToAnotherBranchHasNoCreateRow() throws {
    let repo = try makeRepository()
    XCTAssertTrue(run(["checkout", "-q", "-b", "feat"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["checkout", "-q", "main"], cwd: repo).isSuccess)
    let expanded = run(["check-ref-format", "--branch", "@{-1}"], cwd: repo)
    XCTAssertTrue(expanded.isSuccess, "前提: git は成功として答える")
    XCTAssertEqual(
      expanded.stdoutText.trimmingCharacters(in: .newlines), "feat", "前提: 直前のブランチ名へ展開する")
    let model = WorktreePaletteModel()
    let provider = WorktreePaletteDataProvider(
      cwd: repo, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)
    model.onCheckBranchName = { provider.checkBranchName($0) }
    provider.load()
    XCTAssertTrue(pump { model.newBranchRules != nil })

    for (name, creatable) in [("@{-1}", false), ("topic/new", true)] {
      model.query = name
      model.onQueryChanged()
      XCTAssertTrue(pump { model.branchNameAnswer?.name == name }, "\(name) に答えが届く")
      XCTAssertEqual(
        model.items.contains { $0.action == .createBranch(name: name) }, creatable, name)
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
    let repo = try makeRepository()
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

  /// origin にあるブランチの名前には作成行を出さない（そのリモートブランチの行が作るローカル名と同じ名前の
  /// 別物になる）。
  func testNameOfARemoteBranchIsNotCreatable() throws {
    let origin = try makeRepository()
    XCTAssertTrue(run(["branch", "feat/x"], cwd: origin).isSuccess)
    let clone = dir.appendingPathComponent("clone").path
    XCTAssertTrue(run(["clone", "-q", origin, clone], cwd: dir.path).isSuccess)
    XCTAssertTrue(
      run(["branch", "--list", "feat/x"], cwd: clone).stdoutText.isEmpty,
      "前提: 手元に feat/x のローカルブランチは無い")

    let model = WorktreePaletteModel()
    let provider = WorktreePaletteDataProvider(
      cwd: clone, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)
    provider.load()
    XCTAssertTrue(pump { model.newBranchRules != nil })

    let rules = try XCTUnwrap(model.newBranchRules)
    XCTAssertFalse(rules.allows("feat/x"), "origin/feat/x の行が作るローカル名")
    XCTAssertTrue(rules.allows("topic/new"))
  }

  /// git の列挙が着地するまでは、描き直しの契機が来ても一覧を「ロード済み」にしない。開いた直後の ↵ は
  /// 預かられ、一覧が届いてから今の worktree を 1 回だけ開く。
  func testEnterBeforeTheGitListingLandsOpensTheCurrentWorktreeOnceItArrives() throws {
    let repo = try makeRepository()
    let model = WorktreePaletteModel()
    var executed: [WorktreePaletteDestination] = []
    model.onExecute = { executed.append($0) }
    let provider = WorktreePaletteDataProvider(
      cwd: repo, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)

    provider.rebuild()
    XCTAssertFalse(model.hasLoadedOnce, "git の列挙の前は描かない")
    model.activate()
    XCTAssertEqual(executed, [], "↵ は預かられる")

    provider.load()
    XCTAssertTrue(pump { !executed.isEmpty })
    XCTAssertTrue(pump { provider.facts.remoteFetchLanded })
    XCTAssertEqual(executed, [.directory(path: repo)])
  }

  /// 作成先のテンプレートが symlink 配下でも、実体の消えた登録（prunable）と同じ場所になる名前には
  /// 作成行を出さない。git の一覧は登録を実パスで返し、作成先はまだ無いので、字面では一致しない。
  func testNameLandingOnAPrunableWorktreeBehindASymlinkIsNotCreatable() throws {
    let repo = try makeRepository()
    let real = dir.appendingPathComponent("real").path
    let link = dir.appendingPathComponent("link").path
    try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
    XCTAssertTrue(
      run(["worktree", "add", "-q", "-b", "issue/1", "\(link)/issue-1"], cwd: repo).isSuccess)
    try FileManager.default.removeItem(atPath: "\(real)/issue-1")
    XCTAssertTrue(
      run(["worktree", "list", "--porcelain"], cwd: repo).stdoutText.contains("prunable"),
      "前提: 登録は残り、実体は消えている")

    let model = WorktreePaletteModel()
    let provider = WorktreePaletteDataProvider(
      cwd: repo, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: "\(link)/{slug}")
    provider.load()
    XCTAssertTrue(pump { model.newBranchRules != nil })

    let rules = try XCTUnwrap(model.newBranchRules)
    XCTAssertFalse(rules.allows("issue-1"), "作成先が実体の消えた登録と同じ場所")
    XCTAssertTrue(rules.allows("feat/new"))
  }

  /// git の一覧が symlink 経由のパスで登録を返す worktree でも、その中で開けば「現在」の札が付き、
  /// 開いた直後の選択はその worktree になる（⌘T ↵ が別の worktree を開かない）。
  func testCurrentWorktreeRegisteredThroughASymlinkIsSelected() throws {
    let repo = try makeRepository()
    let real = dir.appendingPathComponent("real").path
    let link = dir.appendingPathComponent("link").path
    try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
    XCTAssertTrue(
      run(["worktree", "add", "-q", "-b", "feat", "\(real)/feat"], cwd: repo).isSuccess)
    try "\(link)/feat/.git\n".write(
      toFile: "\(repo)/.git/worktrees/feat/gitdir", atomically: true, encoding: .utf8)
    XCTAssertTrue(
      run(["worktree", "list", "--porcelain"], cwd: repo).stdoutText.contains(
        "worktree \(link)/feat\n"), "前提: 一覧は登録を symlink 経由のパスで返す")

    let model = WorktreePaletteModel()
    let provider = WorktreePaletteDataProvider(
      cwd: "\(real)/feat", model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)
    provider.load()
    XCTAssertTrue(pump { model.hasLoadedOnce })

    XCTAssertEqual(
      model.items.filter(\.isCurrent).map(\.action), [.open(.directory(path: "\(link)/feat"))])
    XCTAssertEqual(model.selectedItem?.action, .open(.directory(path: "\(link)/feat")))
    XCTAssertEqual(model.baseFacts?.current, "feat", "ベースの「現在」もその worktree のブランチ")
  }

  /// `dir/repo` に 1 コミットのリポジトリを作る。
  private func makeRepository() throws -> String {
    let repo = dir.appendingPathComponent("repo").path
    XCTAssertTrue(run(["init", "-q", "-b", "main", repo], cwd: dir.path).isSuccess)
    XCTAssertTrue(run(["config", "user.email", "t@example.com"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["config", "user.name", "t"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo).isSuccess)
    return repo
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

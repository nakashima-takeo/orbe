import XCTest

@testable import Orbe

/// clean の鮮度パイプライン（`DispatchDataProvider`）。実 git の一時リポジトリで、
/// **分類は prune の後にだけ撃つ**・**行ごとの準備完了は発行と着地の帳簿で決まる**・
/// **PR の状態は head 単位で畳む**の 3 点を固定する。
@MainActor
final class DispatchCleanFreshnessTests: OrbeTestCase {
  private var dir: URL!
  private var remote: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-freshness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    XCTAssertTrue(git(["init", "-q", "-b", "main"]).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    try "x".write(
      toFile: dir.appendingPathComponent("a.txt").path, atomically: true, encoding: .utf8)
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
    if let remote { try? FileManager.default.removeItem(at: remote) }
  }

  // MARK: - prune の後にだけ分類する

  /// **prune 前の呼びは分類を撃たない。** prune 前の `refs/remotes/origin/*` には remote で消えた
  /// ref が残っており、そこからの到達性を根拠にすると「消してもコミットは origin に残る」が偽になる。
  func testLoadGitWithoutClassifyingNeverFiresTheProbe() throws {
    let repo = try openRepo()
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)

    provider.loadGit(repo, classifying: false)
    XCTAssertTrue(pump({ !model.sections.isEmpty }), "前提: git レーンは着地している")
    XCTAssertNil(model.classification, "prune 前に分類は出ない")
    XCTAssertTrue(provider.probingPaths.isEmpty, "プローブが 1 本も飛んでいない")

    provider.loadGit(repo, classifying: true)
    XCTAssertTrue(pump({ model.classification != nil }), "分類を許した呼びでは着地する")
  }

  /// **prune が失敗しても分類は始まる。** 手元の ref が最良で、ここで撃たないと clean が
  /// 1 行も出ないまま固まる（remote を持たないリポジトリで `fetch --prune` は必ず落ちる）。
  func testClassificationLandsEvenWhenPruneFails() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.load()
    XCTAssertTrue(pump({ model.classification != nil }, timeout: 30), "prune の失敗で止まらない")
    XCTAssertFalse(provider.classificationPending, "材料が出揃えば待機は解ける")
  }

  /// 非 GitHub リポジトリでは PR 軸に確認対象が無い（`.loaded([])`）ので、**従来どおり git の事実
  /// だけで安全群が立ち、行は確定している**。prune が `[gone]` を確定させて初めてこの行が出る。
  func testNonGitHubRepositoryStillProducesReadySafeRows() throws {
    try makeGoneBranchWithRemote()
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.load()
    XCTAssertTrue(pump({ model.classification != nil }, timeout: 30))
    XCTAssertTrue(pump({ !provider.classificationPending }, timeout: 30))

    let gone = try XCTUnwrap(row(model, branch: "feat/gone"))
    XCTAssertEqual(gone.group, .safe, "gh 抜きでも安全群は機能する")
    XCTAssertTrue(gone.isReady, "確認対象の無い PR 軸は待たない")
    XCTAssertEqual(provider.branchPRStates["feat/gone"], .loaded([]), "確かめて 0 件として畳む")
  }

  // MARK: - 発行と着地の帳簿

  /// **帳簿は多重集合。** 全量発行と差分発行が同じ path に重なったら、両方着地するまで
  /// その行は「揃っていない」（先に着地したほうで確定と読むと、本命より先に選べてしまう）。
  func testProbeLedgerIsAMultiset() throws {
    try makeWorktree("wt-x", branch: "feat/x")
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.load()
    XCTAssertTrue(pump({ model.classification != nil && !provider.classificationPending }))
    let repo = try XCTUnwrap(provider.repo)
    // 比較は git が返した path そのもの（一時ディレクトリは symlink 越しに見える）。
    let path = try XCTUnwrap(row(model, branch: "feat/x")).id
    XCTAssertTrue(try XCTUnwrap(row(model, branch: "feat/x")).isReady, "前提: 一巡した行は確定している")

    provider.startCleanProbe(repo, invalidateAll: true)
    provider.startCleanProbe(repo, invalidateAll: true)
    XCTAssertEqual(provider.probingPaths[path], 2, "重なった発行は 2 本として数える")
    XCTAssertTrue(provider.classificationPending)

    XCTAssertTrue(pump({ provider.probingPaths.isEmpty }, timeout: 30), "着地でどちらも減る")
    XCTAssertTrue(
      try XCTUnwrap(row(model, branch: "feat/x")).isReady, "両方着地して初めて確定へ戻る")
    XCTAssertFalse(provider.classificationPending)
  }

  // MARK: - head 単位の PR 状態

  /// `branchPRStates` の分岐と、**1 本の失敗が他の head を巻き込まない**こと。
  func testBranchPRStatesFoldPerHead() throws {
    try makeWorktree("wt-x", branch: "feat/x")
    try makeWorktree("wt-y", branch: "feat/y")
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.load()
    XCTAssertTrue(pump({ model.classification != nil && !provider.classificationPending }))
    let repo = try XCTUnwrap(provider.repo)

    provider.probedGitHubState = nil
    XCTAssertEqual(
      provider.branchPRStates, ["feat/x": .fetching, "feat/y": .fetching],
      "可否が未確定の間はどの head も取得中（確認前を「確かめた」と読まない）")

    provider.probedGitHubState = .ghMissing
    XCTAssertEqual(
      provider.branchPRStates, ["feat/x": .loaded([]), "feat/y": .loaded([])],
      "gh が使えないと確定したら確認対象そのものが無い")

    provider.probedGitHubState = .ready
    provider.branchPRFetches = ["feat/x": .fetching, "feat/y": .fetching]
    let pr = GitHubBranchPR(
      number: 9, headRefName: "feat/x", state: "OPEN", baseRefName: "main",
      isCrossRepository: false)
    provider.applyFetchedBranchPRs(head: "feat/x", [pr])
    provider.applyFetchedBranchPRs(head: "feat/y", nil)

    XCTAssertEqual(provider.branchPRStates["feat/x"], .loaded([pr]))
    XCTAssertEqual(provider.branchPRStates["feat/y"], .failed, "落ちた head だけが失敗として残る")
    XCTAssertEqual(provider.landedBranchPRs, [pr], "着地した事実は失敗に巻き込まれない")

    DispatchGitHubCache.shared.setBranchPullRequests([], head: "feat/y", for: repo.commonDir)
    XCTAssertEqual(
      provider.branchPRStates["feat/y"], .loaded([]), "前回セッションの結果があればそれで確定させる")
  }

  /// 台帳に無い head（消えた worktree）への遅着は捨てる。
  func testLateLandingForAVanishedHeadIsDropped() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.load()
    XCTAssertTrue(pump({ model.classification != nil && !provider.classificationPending }))
    provider.probedGitHubState = .ready

    let pr = GitHubBranchPR(
      number: 3, headRefName: "feat/gone", state: "OPEN", baseRefName: "main",
      isCrossRepository: false)
    provider.applyFetchedBranchPRs(head: "feat/gone", [pr])
    XCTAssertNil(provider.branchPRFetches["feat/gone"], "発行していない head の着地は記録しない")
  }

  // MARK: - ヘルパ

  private func makeProvider(_ model: DispatchPaletteModel) -> DispatchDataProvider {
    DispatchDataProvider(
      cwd: dir.path, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate)
  }

  /// `origin` を持ち、push 済みブランチの remote 側が消えている（prune で `[gone]` が立つ）形。
  /// origin は github.com ではないので gh レーンは `.notGitHub` に落ちる。
  private func makeGoneBranchWithRemote() throws {
    remote = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-freshness-remote-\(UUID().uuidString)")
    XCTAssertTrue(
      GitRunner.shared.runSync(
        ["init", "-q", "--bare", "-b", "main", remote.path], cwd: dir.path
      ).isSuccess)
    XCTAssertTrue(git(["remote", "add", "origin", remote.path]).isSuccess)
    XCTAssertTrue(git(["push", "-q", "-u", "origin", "main"]).isSuccess)
    XCTAssertTrue(git(["branch", "feat/gone", "main"]).isSuccess)
    XCTAssertTrue(git(["push", "-q", "-u", "origin", "feat/gone"]).isSuccess)
    try makeWorktree("wt-gone", branch: "feat/gone")
    // remote 側だけ消す（手元の remote-tracking ref は prune が落とす）。
    XCTAssertTrue(
      GitRunner.shared.runSync(["branch", "-q", "-D", "feat/gone"], cwd: remote.path).isSuccess)
  }

  private func makeWorktree(_ name: String, branch: String) throws {
    let path = dir.appendingPathComponent(name).path
    let exists = GitRunner.shared.runSync(
      ["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], cwd: dir.path
    ).isSuccess
    let args =
      exists
      ? ["worktree", "add", "-q", path, branch] : ["worktree", "add", "-q", path, "-b", branch]
    XCTAssertTrue(git(args).isSuccess)
  }

  private func row(_ model: DispatchPaletteModel, branch: String) -> CleanRow? {
    model.classification?.first { $0.branch == branch }
  }

  private func openRepo() throws -> GitRepo {
    var opened: GitRepo?
    let done = expectation(description: "GitRepo.open")
    GitRepo.open(cwd: dir.path) {
      opened = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)
    return try XCTUnwrap(opened)
  }

  @discardableResult
  private func git(_ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: dir.path)
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

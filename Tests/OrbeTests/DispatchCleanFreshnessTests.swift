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

  /// **差分発行は全量発行が一度走るまで 1 本も撃たない。** 台帳が無い状態を「全行の比較先が
  /// 変わった」と読むと、prune 前に全行のプローブが飛ぶ——分類を prune の後だけに絞った意味が消える。
  func testDifferentialProbeIsInertUntilTheFirstFullIssuance() throws {
    try makeWorktree("wt-x", branch: "feat/x")
    let repo = try openRepo()
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.loadGit(repo, classifying: false)
    XCTAssertTrue(pump({ !provider.worktrees.isEmpty }), "前提: worktree 一覧は着地している")

    provider.startCleanProbe(repo, .changedTargets)
    XCTAssertTrue(provider.probingPaths.isEmpty, "台帳が無い間は差分を撃たない")
    XCTAssertNil(model.classification, "prune 前に分類は出ない")

    provider.startCleanProbe(repo, .all)
    XCTAssertFalse(provider.probingPaths.isEmpty, "全量発行で初めて飛ぶ")
  }

  /// **gh が prune より先に着地しても、そこでプローブは飛ばない。** gh の往復は 1 本 1 秒前後・
  /// prune は数秒なので、実機で日常的に起きる順序。ここが破れると最初の確定が prune 前データで
  /// 起き、prune 後に安全群へ移った行が二度と自動チェックされない（確定は 1 度きりなので）。
  func testGitHubLandingBeforePruneFiresNoProbe() throws {
    try makeSlowRemote()
    try makeWorktree("wt-x", branch: "feat/x")
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.load()
    // prune は数秒かかるので、worktree 一覧の着地だけを待てば「prune 未着地」の窓に居る。
    XCTAssertTrue(pump({ !provider.worktrees.isEmpty }))
    XCTAssertNil(model.classification, "前提: まだ prune が着地していない")

    // ここから先は同期。completion はメインで返るので、この間に prune が割り込むことはない。
    provider.probedGitHubState = .ready
    provider.branchPRFetches = ["feat/x": .fetching]
    provider.applyFetchedBranchPRs(
      head: "feat/x",
      [
        GitHubBranchPR(
          number: 5, headRefName: "feat/x", state: "MERGED", baseRefName: "develop",
          isCrossRepository: false)
      ])
    XCTAssertTrue(provider.probingPaths.isEmpty, "gh 着地は prune 前にプローブを撃たない")
    XCTAssertNil(model.classification)

    XCTAssertTrue(pump({ model.classification != nil }, timeout: 30), "prune 着地後に初めて分類が出る")
    XCTAssertTrue(pump({ !provider.classificationPending }, timeout: 30))
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

    provider.startCleanProbe(repo, .all)
    provider.startCleanProbe(repo, .all)
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

    // 未発行／取得中の head も同じ先描きに載る（ここが `.fetching` へ退化すると、開き直すたびに
    // 全行がスケルトンへ戻る）。
    provider.branchPRFetches = [:]
    XCTAssertEqual(provider.branchPRStates["feat/y"], .loaded([]), "未発行でも前回結果で先に描く")
    XCTAssertEqual(provider.branchPRStates["feat/x"], .fetching, "前回結果が無い head は取得中のまま")
  }

  /// **同じブランチを持つ worktree が 2 本あっても、問う head は 1 つ。** `git worktree add --force`
  /// は二重チェックアウトを通すので、worktree の並びをそのまま head の並びにすると同名が 2 度出る
  /// ——それを辞書へ起こす `branchPRStates` は重複キーで落ち、そのリポジトリではパレットが開けなくなる。
  func testDuplicateBranchWorktreesFoldIntoOneHead() throws {
    try makeWorktree("wt-x", branch: "feat/x")
    XCTAssertTrue(
      git(["worktree", "add", "--force", "-q", dir.appendingPathComponent("wt-x2").path, "feat/x"])
        .isSuccess, "前提: --force は二重チェックアウトを通す")
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)

    provider.load()
    XCTAssertTrue(pump({ model.classification != nil && !provider.classificationPending }))

    XCTAssertEqual(
      provider.worktrees.filter { $0.branch == "feat/x" }.count, 2, "前提: 同じ head の worktree が 2 本")
    XCTAssertEqual(
      DispatchDataProvider.branchPRHeads(of: provider.worktrees), ["feat/x"], "問う head は 1 つに畳む")
    XCTAssertEqual(provider.branchPRStates.count, 1)
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

  /// `fetch --prune` が数秒かかる origin を用意する（gh の着地が prune より先に来る実機の順序を
  /// 手元で再現するため）。`uploadpack` を眠るラッパーへ差し替えるだけなので、特別な transport も
  /// ネットワークも要らない。
  private func makeSlowRemote() throws {
    remote = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-freshness-slow-\(UUID().uuidString)")
    XCTAssertTrue(
      GitRunner.shared.runSync(
        ["init", "-q", "--bare", "-b", "main", remote.path], cwd: dir.path
      ).isSuccess)
    XCTAssertTrue(git(["remote", "add", "origin", remote.path]).isSuccess)
    XCTAssertTrue(git(["push", "-q", "-u", "origin", "main"]).isSuccess)
    let wrapper = dir.appendingPathComponent("slow-upload-pack").path
    try "#!/bin/sh\nsleep 2\nexec git-upload-pack \"$@\"\n".write(
      toFile: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
    XCTAssertTrue(git(["config", "remote.origin.uploadpack", wrapper]).isSuccess)
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

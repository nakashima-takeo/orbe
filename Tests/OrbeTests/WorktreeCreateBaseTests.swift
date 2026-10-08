import OrbeTestSupport
import XCTest

@testable import Orbe

/// 新規ブランチを切る worktree 作成の**ベースの鮮度と upstream**（`WorktreePaletteDataProvider`）。
/// 実 git の一時リポジトリ（bare origin ＋ 2 つの clone）で、提示時に走る `fetch --prune` の着地を
/// 待ってから作ること・新しいブランチに upstream が付かないことを固定する。
///
/// ここが破れると、パレットを開いてすぐ Enter した worktree が GitHub でマージ済みの変更を含まない
/// 古いベースから切られ、その上でエージェントが仕事を始める。upstream が破れると新しいブランチで
/// `git push` がベースへ向かって拒否される。
///
/// 遅い fetch は `remote.origin.uploadpack` を眠るラッパーへ差し替えて作る（ネットワーク不要）。
/// 「待っている」ことは所要時間ではなく**出来上がった HEAD**で測る——待たなければ手元の古い
/// `refs/remotes/origin/*` が base になり、origin の新しい tip とは一致しない。
@MainActor
final class WorktreeCreateBaseTests: OrbeTestCase {
  var dir: URL!
  var local: String!
  var origin: String!
  /// provider が弱参照で持つモデル（行の同期を読むテストのために生かしておく）。
  var palette: WorktreePaletteModel!

  /// `main` / `feat` / `stale` を持つ origin を立て、手元の clone の remote 追跡 ref を**わざと
  /// 古いまま**にする。`mine` は upstream の無い手元だけのローカルブランチ（着地を待たない題材）、
  /// `stale` は origin を追跡する手元のブランチ（分冊 `+Refresh` の題材）。
  override func setUpWithError() throws {
    dir = TestScratch.caseDir
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
    for branch in ["feat", "stale"] {
      XCTAssertTrue(run(["checkout", "-q", "-b", branch, "main"], cwd: other).isSuccess)
      try commit("\(branch)-1", in: other)
      XCTAssertTrue(run(["push", "-q", "-u", "origin", branch], cwd: other).isSuccess)
    }

    // ここまでを手元へ取り込み、`origin/HEAD` を据える（通常の clone と同じ形）。
    XCTAssertTrue(run(["fetch", "-q", "origin"], cwd: local).isSuccess)
    XCTAssertTrue(
      run(
        ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], cwd: local
      ).isSuccess)
    // `stale` は origin を追跡する手元のブランチ（checkout していない＝Local branch 行の題材）。
    XCTAssertTrue(run(["branch", "-q", "--track", "stale", "origin/stale"], cwd: local).isSuccess)

    // 以降の origin 側の前進は手元に入らない＝手元の remote 追跡 ref は古い。
    for branch in ["main", "feat", "stale"] {
      XCTAssertTrue(run(["checkout", "-q", branch], cwd: other).isSuccess)
      try commit("\(branch)-2", in: other)
      XCTAssertTrue(run(["push", "-q", "origin", branch], cwd: other).isSuccess)
      XCTAssertNotEqual(
        originTip(branch), localRemoteTip(branch), "前提: 手元の origin/\(branch) は古い")
    }
  }

  // MARK: - fetch の着地を待ってから切る

  /// 既定ブランチからの新しいブランチは `origin/<既定ブランチ>` から切るので、提示時の fetch が着地してから作る。
  func testNewBranchIsCutFromTheFetchedDefaultBranch() throws {
    let provider = try startWithSlowFetch()
    XCTAssertTrue(
      pump({ provider.defaultBranchName == "origin/main" }), "前提: 既定ブランチの解決は着地している")
    let outcome = try prepare(provider, .newBranch(name: "issue/44", base: .defaultBranch))
    guard case .created(let path, let base) = outcome else {
      return XCTFail("新しいブランチの作成として返る: \(outcome)")
    }
    XCTAssertEqual(head(of: path), originTip("main"), "fetch 後の origin/main が base")
    XCTAssertEqual(base, "origin/main", "使ったベースは意図ではなく解決後の名前で返る（前回として覚える値）")
  }

  /// ベースのバーで名前のブランチ（前回・現在・ほかで選んだもの）を選んだときも、そのブランチから
  /// fetch の着地後に切り、使ったベースはその名前で返る。
  func testNewBranchIsCutFromTheChosenBranchAfterTheFetch() throws {
    let provider = try startWithSlowFetch()
    let outcome = try prepare(provider, .newBranch(name: "issue/45", base: .ref("origin/feat")))
    guard case .created(let path, let base) = outcome else {
      return XCTFail("新しいブランチの作成として返る: \(outcome)")
    }
    XCTAssertEqual(head(of: path), originTip("feat"), "fetch 後の origin/feat が base")
    XCTAssertEqual(base, "origin/feat")
  }

  /// Remote branch 行も remote ref から新しいローカルブランチを切る経路。
  func testRemoteBranchWorktreeIsCutFromTheFetchedRemoteRef() throws {
    let provider = try startWithSlowFetch()
    let path = try resolve(provider, .remoteBranch(name: "origin/feat", existingWorktree: nil))
    XCTAssertEqual(head(of: path), originTip("feat"), "fetch 後の origin/feat が base")
  }

  /// **upstream の無い Local branch の checkout は fetch で動く ref をベースに取らないので待たない。**
  /// ここが待つと、fetch が長引くリポジトリで「手元のブランチを開くだけ」が分単位で止まる
  /// （origin を追跡する行は着地を待つ——分冊 `+Refresh`）。
  ///
  /// 待たなかった証拠は、作成が返った時点で手元の `origin/main` がまだ古いこと——fetch が着地して
  /// いれば ref は新しい tip へ動いている。**この否定の assert を測る窓だけは壁時計で区切らない**
  /// ——窓の中で作成（非同期 git 2 本）を走らせるので、遅い機械では窓が先に閉じて「正しい実装のまま
  /// 赤」になる。fetch はテストが門を開けるまで待たせ、作成が返ってから開ける。
  func testLocalBranchWithoutUpstreamDoesNotWaitForTheFetch() throws {
    let provider = try startWithSlowFetch(holdingFetch: true)
    let path = try resolve(provider, .localBranch(name: "mine"))
    XCTAssertNotEqual(
      localRemoteTip("main"), originTip("main"), "作成が返った時点で fetch はまだ着地していない")
    XCTAssertEqual(head(of: path), oid(["rev-parse", "mine"], cwd: local))
    releaseFetch()
  }

  /// **fetch が失敗しても作成は続く。** 手元の `refs/remotes/origin/*` が最良で、ここで止めると
  /// origin へ到達できない環境で新規ブランチの作成そのものが出来なくなる。
  func testCreationContinuesWhenTheFetchFails() throws {
    XCTAssertTrue(
      run(["remote", "set-url", "origin", dir.appendingPathComponent("gone.git").path], cwd: local)
        .isSuccess)
    let provider = try start()

    let created = try resolve(
      provider, .newBranch(name: "issue/44", base: .defaultBranch))
    XCTAssertEqual(head(of: created), localRemoteTip("main"), "新しいブランチ: 手元の origin/main から続行")
    let remote = try resolve(provider, .remoteBranch(name: "origin/feat", existingWorktree: nil))
    XCTAssertEqual(
      head(of: remote), localRemoteTip("feat"), "Remote branch: 手元の origin/feat から続行")
  }

  // MARK: - upstream

  /// **新しいブランチは upstream を持たない。** ベース（`origin/<既定>` 等）を追跡すると `git push` が
  /// ベースへ向かって拒否され（`push.default=simple`）、upstream が既にあるので
  /// `push.autoSetupRemote` も発動しない。remote ref から起こす経路（Remote branch 行の作成）は逆に、
  /// 同名の remote ブランチを追跡する。
  func testNewBranchHasNoUpstreamWhileRemoteRefBranchesTrackOrigin() throws {
    // 追跡の指定を省くと既定が効いてしまう設定。契約が環境に左右されないことをここで測る。
    XCTAssertTrue(run(["config", "branch.autoSetupMerge", "always"], cwd: local).isSuccess)
    let provider = try start()
    _ = try resolve(provider, .newBranch(name: "issue/44", base: .defaultBranch))
    _ = try resolve(provider, .remoteBranch(name: "origin/feat", existingWorktree: nil))

    XCTAssertFalse(
      run(["config", "--get", "branch.issue/44.merge"], cwd: local).isSuccess,
      "新しいブランチに upstream は付かない")
    XCTAssertEqual(oid(["config", "--get", "branch.feat.remote"], cwd: local), "origin")
    XCTAssertEqual(oid(["config", "--get", "branch.feat.merge"], cwd: local), "refs/heads/feat")
  }

  // MARK: - 既定ブランチが remote から引けない repo

  /// remote を持たないリポジトリでも既定ブランチからの新規は成功する（`origin/HEAD` が引けず `main` へ落ちる）。
  func testNewBranchWorksWithoutARemote() throws {
    XCTAssertTrue(run(["remote", "remove", "origin"], cwd: local).isSuccess)
    let provider = try start()
    let path = try resolve(
      provider, .newBranch(name: "issue/44", base: .defaultBranch))
    XCTAssertEqual(head(of: path), oid(["rev-parse", "main"], cwd: local))
  }

  /// **fetch が `origin/HEAD` を作ったなら、その名前で切る。** 着地をベース ref の中身だけで測ると、
  /// 名前は提示時の読み（フォールバックの固定名）のまま撃たれ、既定が `main` でない repo では
  /// 存在しない ref を指す。ここでは手元の `main`（古い）と `origin/main`（fetch 後）が別物なので、
  /// どちらの名前で切ったかが HEAD に出る。
  ///
  /// Enter は fetch が未着地の窓で撃つ——窓を作らないと、fetch が Enter より先に明けた回は名前を
  /// 提示時に捕まえる実装でも緑になる。
  func testNewBranchUsesTheDefaultBranchDiscoveredByTheFetch() throws {
    XCTAssertTrue(
      run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], cwd: local).isSuccess)
    let provider = try startWithSlowFetch()
    XCTAssertEqual(provider.defaultBranchName, "main", "前提: 提示時の名前はフォールバック")
    let path = try resolve(
      provider, .newBranch(name: "issue/44", base: .defaultBranch))
    XCTAssertEqual(
      oid(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: local), "origin/main",
      "前提: fetch が origin/HEAD を作り直している")
    XCTAssertEqual(head(of: path), originTip("main"), "fetch 後に解決した origin/main が base")
  }

  // MARK: - ヘルパ

  struct CreationFailed: Error {
    let detail: String
  }

  /// provider を起こし、git レーンの着地（列挙 → 行の組み直し）まで進める。
  func start() throws -> WorktreePaletteDataProvider {
    palette = WorktreePaletteModel()
    let provider = WorktreePaletteDataProvider(
      cwd: local, model: palette, localization: LocalizationStore(language: .ja),
      // 作成先を一時ディレクトリの中へ落とす（後始末に乗せる）。
      worktreeTemplate: "{parent}/wt-{slug}")
    provider.load()
    XCTAssertTrue(
      pump({
        palette.items.contains { $0.glyph == .worktree }
          && palette.items.contains { $0.glyph == .localBranch }
      }), "前提: git レーンは着地している（worktree 行と Local branch 行が組まれるまで）")
    return provider
  }

  /// fetch を遅らせてから provider を起こす。返るのは fetch が未着地の窓に居る provider——ここで
  /// 作成を撃たないと「待つかどうか」を測れない。遅延は `remote.origin.uploadpack` を眠るラッパーへ
  /// 差し替えて作る（ネットワークも特別な transport も要らない）。
  ///
  /// `holdingFetch` は眠りを `releaseFetch()` まで続けさせる。着地を待ち切るまで手が戻らないテスト
  /// （`resolve`・`prepare` の中で着地を待つ等）は fetch が自力で明ける必要があるので数秒の眠りのまま、
  /// 着地の前と後を分けて測るテストが門を使い、自分で `releaseFetch()` を呼ぶ。
  func startWithSlowFetch(holdingFetch: Bool = false) throws
    -> WorktreePaletteDataProvider
  {
    let wrapper = dir.appendingPathComponent("slow-upload-pack").path
    if holdingFetch {
      try FileManager.default.createDirectory(
        atPath: fetchGate, withIntermediateDirectories: true)
    }
    let wait = holdingFetch ? "while [ -d \"\(fetchGate)\" ]; do sleep 0.05; done" : "sleep 2"
    try "#!/bin/sh\n\(wait)\nexec git-upload-pack \"$@\"\n".write(
      toFile: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
    XCTAssertTrue(run(["config", "remote.origin.uploadpack", wrapper], cwd: local).isSuccess)
    let provider = try start()
    XCTAssertNotEqual(localRemoteTip("main"), originTip("main"), "前提: まだ fetch が着地していない")
    return provider
  }

  /// fetch を止めている門。消えた時点で `uploadpack` のラッパーが先へ進む。
  private var fetchGate: String { dir.appendingPathComponent("fetch-gate").path }

  func releaseFetch() {
    try? FileManager.default.removeItem(atPath: fetchGate)
  }

  func resolve(_ provider: WorktreePaletteDataProvider, _ destination: WorktreePaletteDestination)
    throws
    -> String
  {
    switch try prepare(provider, destination) {
    case .resolved(.ready(let path)), .created(let path, _): return path
    case let outcome: throw CreationFailed(detail: String(describing: outcome))
    }
  }

  func prepare(_ provider: WorktreePaletteDataProvider, _ destination: WorktreePaletteDestination)
    throws
    -> WorktreePaletteDataProvider.PrepareOutcome
  {
    var outcome: WorktreePaletteDataProvider.PrepareOutcome?
    provider.prepareDirectory(for: destination) { outcome = $0 }
    XCTAssertTrue(pump({ outcome != nil }, timeout: 30), "解決が返らない")
    return try XCTUnwrap(outcome)
  }

  private func identify(_ repo: String) throws {
    XCTAssertTrue(run(["config", "user.email", "t@example.com"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["config", "user.name", "t"], cwd: repo).isSuccess)
  }

  func commit(_ name: String, in repo: String) throws {
    try name.write(
      toFile: (repo as NSString).appendingPathComponent("\(name).txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(run(["add", "-A"], cwd: repo).isSuccess)
    XCTAssertTrue(run(["commit", "-qm", name], cwd: repo).isSuccess)
  }

  func head(of worktree: String) -> String {
    oid(["rev-parse", "HEAD"], cwd: worktree)
  }

  func originTip(_ branch: String) -> String {
    oid(["rev-parse", branch], cwd: origin)
  }

  private func localRemoteTip(_ branch: String) -> String {
    oid(["rev-parse", "origin/\(branch)"], cwd: local)
  }

  func oid(_ args: [String], cwd: String) -> String {
    run(args, cwd: cwd).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func run(_ args: [String], cwd: String) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd)
  }

  /// main queue を回しながら条件の成立を待つ（provider の completion は main で届く）。
  func pump(_ condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      usleep(5_000)
    }
    return condition()
  }
}

import XCTest

@testable import Orbe

/// 遅れた Local branch の最新化（`DispatchDataProvider`）。`DispatchWorktreeBaseTests` と同じ
/// 実 git の一時リポジトリで、Enter の判定が fetch の着地を待つこと・fetch → fast-forward → 作成が
/// 1 アクションで通ること・分岐と checkout 中は git が拒んでローカルが無傷なことを固定する。
///
/// ここが破れると、遅れたブランチの worktree が黙って古い地点から始まるか、逆にユーザーが選んでいない
/// のにローカルの ref が動く。
@MainActor
extension DispatchWorktreeBaseTests {

  /// **origin を追跡する Local branch の Enter は fetch の着地を待ち、着地後の値で判定する。**
  /// 提示時点では `stale` は同期済みに見える（手元の `origin/stale` が古い）——着地前の値で決めると、
  /// 速く押した人だけが最新化を選べない。遅れが分かったら worktree を作らずに問う。
  func testStaleLocalBranchIsReportedAfterTheFetchLands() throws {
    let provider = try startWithSlowFetch()
    guard
      case .staleBranch(let sync, let relativeDate) = try prepare(
        provider, .localBranch(name: "stale"))
    else {
      return XCTFail("着地後の値で遅れを返す")
    }
    XCTAssertEqual(sync.name, "stale")
    XCTAssertEqual(sync.upstream.short, "origin/stale")
    XCTAssertEqual(sync.ahead, 0)
    XCTAssertEqual(sync.behind, 1)
    XCTAssertFalse(relativeDate.isEmpty, "最新化の画面が「そのまま作成」に出すブランチの相対日時")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent("wt-stale").path),
      "問うだけで作らない")
  }

  /// 分岐（↑↓）は fast-forward できないので選択画面には入らず、今どおり手元の地点から作る。
  func testDivergedLocalBranchIsCreatedAsIs() throws {
    let localTip = advanceLocally("stale")
    let provider = try start()
    XCTAssertTrue(pump({ provider.remoteFetchLanded }), "前提: 着地している")
    let path = try resolve(provider, .localBranch(name: "stale"))
    XCTAssertEqual(head(of: path), localTip)
  }

  /// **「最新化して作成」は fetch → fast-forward → 作成を 1 アクションで通す。** 出来上がった worktree
  /// も手元の `stale` も origin の tip を指す。`creating` は ff が済んだ後・作成の前に 1 度呼ばれる。
  func testRefreshAndCreateFastForwardsThenCreates() throws {
    let provider = try start()
    let sync = try staleSync(provider)
    var creatingCalls = 0
    var result: Result<DispatchDataProvider.DirectoryResolution, GitRefreshFailure>?
    provider.refreshAndCreate(sync, creating: { creatingCalls += 1 }, completion: { result = $0 })
    XCTAssertTrue(pump({ result != nil }, timeout: 30))
    guard case .success(.ready(let path)) = try XCTUnwrap(result) else {
      return XCTFail("\(String(describing: result))")
    }
    XCTAssertEqual(creatingCalls, 1)
    XCTAssertEqual(head(of: path), originTip("stale"))
    XCTAssertEqual(oid(["rev-parse", "stale"], cwd: local), originTip("stale"), "ローカル ref が進む")
    XCTAssertNil(palette.items.first { $0.name == "stale" }?.sync, "引き直しでピルが消える")
  }

  /// **分岐していれば進めない。** origin 側が書き換えられていたら ff 段で落ち、ローカルの ref は無傷。
  func testRefreshRefusesWhenTheUpstreamDiverged() throws {
    let provider = try start()
    let sync = try staleSync(provider)
    let other = dir.appendingPathComponent("other").path
    // origin の `stale` を main から切り直す（手元の tip がその祖先でなくなる）。
    XCTAssertTrue(run(["checkout", "-q", "stale"], cwd: other).isSuccess)
    XCTAssertTrue(run(["reset", "-q", "--hard", "main"], cwd: other).isSuccess)
    XCTAssertTrue(run(["commit", "-q", "--allow-empty", "-m", "rewritten"], cwd: other).isSuccess)
    XCTAssertTrue(run(["push", "-q", "-f", "origin", "stale"], cwd: other).isSuccess)
    let before = oid(["rev-parse", "stale"], cwd: local)

    var result: Result<DispatchDataProvider.DirectoryResolution, GitRefreshFailure>?
    provider.refreshAndCreate(
      sync, creating: { XCTFail("作成に進まない") }, completion: { result = $0 })
    XCTAssertTrue(pump({ result != nil }, timeout: 30))
    guard case .failure(.fastForward(nil)) = try XCTUnwrap(result) else {
      return XCTFail("\(String(describing: result))")
    }
    XCTAssertEqual(oid(["rev-parse", "stale"], cwd: local), before, "ローカル ref は無傷")
  }

  /// **checkout 中のブランチは git 自身が拒む。** 提示時に worktree が無くても、開いている間に裏で
  /// checkout され得るので、書き込みの瞬間の検査に委ねる。
  func testRefreshRefusesABranchCheckedOutMeanwhile() throws {
    let provider = try start()
    let sync = try staleSync(provider)
    let elsewhere = dir.appendingPathComponent("elsewhere").path
    XCTAssertTrue(run(["worktree", "add", "-q", elsewhere, "stale"], cwd: local).isSuccess)
    let before = oid(["rev-parse", "stale"], cwd: local)

    var result: Result<DispatchDataProvider.DirectoryResolution, GitRefreshFailure>?
    provider.refreshAndCreate(sync, creating: {}, completion: { result = $0 })
    XCTAssertTrue(pump({ result != nil }, timeout: 30))
    guard case .failure(.fastForward(.some(.reason(let reason)))) = try XCTUnwrap(result) else {
      return XCTFail("\(String(describing: result))")
    }
    XCTAssertTrue(reason.contains("checked out"), reason)
    XCTAssertEqual(oid(["rev-parse", "stale"], cwd: local), before)
  }

  /// **「そのまま作成」は同期の検査を通らない。** 遅れた枝でも手元の地点から作り、ローカルの ref は
  /// 動かさない——検査を通すと再び「遅れている」が返り、選択画面から前へ進めなくなる。
  func testCreateAsIsStartsFromTheLocalTipAndLeavesTheRefAlone() throws {
    let provider = try start()
    let sync = try staleSync(provider)
    let before = oid(["rev-parse", "stale"], cwd: local)
    XCTAssertNotEqual(before, originTip("stale"), "前提: 遅れている")

    var resolution: DispatchDataProvider.DirectoryResolution?
    provider.createLocalBranchWorktree(name: sync.name) { resolution = $0 }
    XCTAssertTrue(pump({ resolution != nil }, timeout: 30))
    guard case .ready(let path) = try XCTUnwrap(resolution) else {
      return XCTFail("\(String(describing: resolution))")
    }
    XCTAssertEqual(head(of: path), before, "遅れたまま手元の地点から作る")
    XCTAssertEqual(oid(["rev-parse", "stale"], cwd: local), before, "ローカル ref は動かない")
  }

  /// fetch が落ちたら fetch 段の失敗として返り、ローカルは無傷。
  func testRefreshReportsFetchFailure() throws {
    let provider = try start()
    let sync = try staleSync(provider)
    XCTAssertTrue(
      run(["remote", "set-url", "origin", dir.appendingPathComponent("gone.git").path], cwd: local)
        .isSuccess)
    var result: Result<DispatchDataProvider.DirectoryResolution, GitRefreshFailure>?
    provider.refreshAndCreate(sync, creating: {}, completion: { result = $0 })
    XCTAssertTrue(pump({ result != nil }, timeout: 30))
    guard case .failure(.fetch(.reason(let reason))) = try XCTUnwrap(result) else {
      return XCTFail("\(String(describing: result))")
    }
    XCTAssertTrue(reason.contains("fatal:"), reason)
  }

  /// 着地後の `stale`（origin より 1 遅れ）の同期を一覧の行から読む。
  private func staleSync(_ provider: DispatchDataProvider) throws -> DispatchBranchSync {
    XCTAssertTrue(pump({ provider.remoteFetchLanded }), "前提: 着地している")
    let sync = try XCTUnwrap(palette.items.first { $0.name == "stale" }?.sync)
    XCTAssertTrue(sync.isFastForwardable)
    return sync
  }

  /// checkout せずに手元のブランチへ空コミットを 1 つ積む（分岐の題材）。返るのは新しい tip。
  private func advanceLocally(_ branch: String) -> String {
    let tree = oid(["rev-parse", "\(branch)^{tree}"], cwd: local)
    let commit = oid(["commit-tree", tree, "-p", branch, "-m", "local"], cwd: local)
    XCTAssertTrue(run(["update-ref", "refs/heads/\(branch)", commit], cwd: local).isSuccess)
    return commit
  }
}

import XCTest

@testable import Orbe

/// 無応答の git を打ち切る仕組みの検証。測るのは経過時間ではなく**無出力が続いた時間**——
/// 巨大リポジトリの clone のような正当な長時間実行を切らずに、認証待ち・hook のハング・
/// ネットワーク停止だけを切るには、測る対象がこれでなければならない。
///
/// ここが壊れると、返らない git を待つ UI が永久に固まる（打ち切りが効かない）か、
/// 進捗が流れているだけの正常な clone を途中で殺す（アイドル判定が壊れる）。
/// 打ち切った後に EOF を待ってしまう実装も同じく致命で、セッションごと抜けた孫（daemon 化した
/// hook の子）が pipe の書き込み端を握ったままなので、**切ったのに返らない**を作り直す。
final class GitRunnerTimeoutTests: OrbeTestCase {
  /// 本番の 120 秒は待てないので、短いアイドル上限を持つ専用インスタンスで駆動する
  /// （`shared` のキューを一切汚さない）。
  private let runner = GitRunner(idleTimeout: 0.6)
  private var fixture: GitHangFixture!

  override func setUpWithError() throws {
    fixture = try GitHangFixture()
    addTeardownBlock { [fixture] in fixture?.cleanup() }
  }

  // MARK: - ヘルパ

  /// `runSync` は同期なので背景で走らせ、期限つきで受ける（返らない実装でテストプロセスを固めない）。
  private func runSync(
    _ args: [String], cwd: String? = nil, timeout: TimeInterval = 20
  ) throws -> GitRunner.Output {
    var result: GitRunner.Output?
    let done = expectation(description: args.joined(separator: " "))
    let dir = cwd ?? fixture.root
    DispatchQueue.global(qos: .userInitiated).async { [runner] in
      let output = runner.runSync(args, cwd: dir)
      DispatchQueue.main.async {
        result = output
        done.fulfill()
      }
    }
    wait(for: [done], timeout: timeout)
    return try XCTUnwrap(result)
  }

  /// commit させる変更を 1 つ作って index に載せる。
  private func stageChange() throws {
    try "changed\n".write(
      toFile: (fixture.root as NSString).appendingPathComponent("a.txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(fixture.git(["add", "-A"]).isSuccess)
  }

  private var indexLockPath: String {
    (fixture.root as NSString).appendingPathComponent(".git/index.lock")
  }

  /// index を書いている最中に止まる形を作る。`git add` は clean フィルタの出力を待つ間、
  /// index の lock を握ったままになる。
  private func installHangingCleanFilter() throws {
    let filter = try fixture.installScript("hang-filter.sh", script: fixture.waitingScript)
    XCTAssertTrue(fixture.git(["config", "filter.hang.clean", filter]).isSuccess)
    try "*.big filter=hang\n".write(
      toFile: (fixture.root as NSString).appendingPathComponent(".gitattributes"),
      atomically: true, encoding: .utf8)
    try "payload\n".write(
      toFile: (fixture.root as NSString).appendingPathComponent("big.big"), atomically: true,
      encoding: .utf8)
  }

  /// lock が現れるまで待つ（フィルタ起動と lock 取得の順序に依存しないため）。
  private func waitForIndexLock(timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: indexLockPath) { return true }
      usleep(10_000)
    }
    return false
  }

  /// 返らない `ext::` transport を相手にした clone。clone は hook を持たないので、止める手段は
  /// これだけ（`protocol.ext.allow` は既定で拒否なので、テストが明示的に開ける）。
  private func cloneFromHangingRemote() throws -> (output: GitRunner.Output, dest: String) {
    let helper = try fixture.installScript("hang-remote.sh", script: fixture.waitingScript)
    let dest = fixture.dir.appendingPathComponent("clone-dst").path
    let output = try runSync(
      ["-c", "protocol.ext.allow=always", "clone", "--progress", "ext::\(helper)", dest],
      cwd: fixture.dir.path)
    return (output, dest)
  }

  // MARK: - 打ち切る / 打ち切らない

  /// 無出力のまま止まった git は打ち切られる。`timedOut` で見分けられ、成功にはならない。
  func testSilentCommandIsStoppedAfterIdleTimeout() throws {
    try fixture.installHook("pre-commit", script: fixture.waitingScript)
    try stageChange()

    let output = try runSync(["commit", "-m", "blocked"])

    XCTAssertTrue(output.timedOut, "無出力のまま上限を過ぎたら打ち切る")
    XCTAssertFalse(output.isSuccess, "打ち切った実行を成功として扱ってはいけない")
  }

  /// 出力が流れている限り、総経過時間が上限を超えても打ち切らない。
  /// **アイドル方式であることの歯**——絶対時間で測る実装ならここが落ちる。
  func testStreamingCommandIsNotStopped() throws {
    try fixture.installHook("pre-commit", script: GitHangFixture.streamingScript)
    try stageChange()

    let output = try runSync(["commit", "-m", "slow but alive"])

    XCTAssertFalse(output.timedOut, "0.2 秒ごとに出力があるなら、合計 1.0 秒でも切ってはいけない")
    XCTAssertTrue(output.isSuccess, "完走した commit は成功する")
  }

  /// 打ち切った後、**孫プロセスが pipe の書き込み端を握っていても**返る。
  /// `terminate()` のあと無期限に EOF を待つ実装（既存 `GitHubCLI` の形）だとここで返らない。
  func testStoppedRunReturnsWhileGrandchildHoldsThePipes() throws {
    try fixture.installHook("pre-commit", script: fixture.pipeHoldingScript)
    try stageChange()

    let started = Date()
    let output = try runSync(["commit", "-m", "blocked"])
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertTrue(output.timedOut)
    XCTAssertGreaterThan(
      elapsed, 1.0, "前提: 孫が pipe を握っていて EOF が来ず、打ち切り後の猶予を使い切っていること")
    XCTAssertLessThan(
      elapsed, 10, "打ち切りの後に EOF を無期限に待つと、直したいハングを別の場所で作り直すことになる")
  }

  // MARK: - 後始末（git 自身の SIGTERM 処理に依存する事実。変わったら気づけるよう固定する）

  /// 打ち切った clone は宛先ディレクトリを残さない（SIGTERM を受けた git 自身が掃除する）。
  /// SIGKILL で殺すと作りかけが残り、次の clone が「既に存在する」で詰む。
  func testStoppedCloneLeavesNoDestination() throws {
    let result = try cloneFromHangingRemote()

    XCTAssertTrue(result.output.timedOut)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: result.dest), "作りかけの clone 先を残さない")
  }

  /// 打ち切りは `.git/index.lock` を残さず、後続の git 操作がそのまま通る。
  ///
  /// **lock を実際に握っている形で測ること。** `pre-commit` hook のハングでは git はまだ lock を
  /// 取っていないので、SIGKILL に変えても lock は残らない＝何も測らないテストになる（実測）。
  /// index を書いている最中に止まる形として、clean フィルタ（git-lfs と同じ仕組み）が返らない
  /// `git add` を使う。この形なら、ハング中 lock あり → SIGTERM 後は無し → SIGKILL なら残る、と
  /// 三者が分かれる。
  func testStoppedIndexWriteLeavesNoIndexLock() throws {
    try installHangingCleanFilter()

    var result: GitRunner.Output?
    let done = expectation(description: "add")
    DispatchQueue.global(qos: .userInitiated).async { [runner, root = fixture.root] in
      let output = runner.runSync(["add", "--", "big.big"], cwd: root)
      DispatchQueue.main.async {
        result = output
        done.fulfill()
      }
    }
    XCTAssertTrue(fixture.waitUntilHung(), "前提: clean フィルタがハングしている")
    XCTAssertTrue(
      waitForIndexLock(), "前提: このとき index.lock が握られている（偽ならこのテストは何も測らない）")
    wait(for: [done], timeout: 20)

    XCTAssertTrue(try XCTUnwrap(result).timedOut)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: indexLockPath),
      "SIGTERM を受けた git が lock を掃除する。残ると以後この repo への書き込みが全部 fatal になる")
    XCTAssertTrue(try runSync(["status", "--porcelain"]).isSuccess, "後続の git 操作が通る")
  }

  // MARK: - 打ち切り後の読み替えと巻き添えの不在

  /// post-checkout hook は worktree が出来上がった**後**に走る。hook が返らず打ち切っても
  /// worktree は完成しているので、**成功として返す**。失敗にすると、実在する worktree を指したまま
  /// 再実行が `fatal: a branch named 'x' already exists` で詰む——直した数より多く壊す。
  func testStoppedWorktreeAddSucceedsWhenTheWorktreeExists() throws {
    try fixture.installHook("post-checkout", script: fixture.waitingScript)
    var repo: GitRepo?
    let opened = expectation(description: "GitRepo.open")
    GitRepo.open(cwd: fixture.root, runner: runner) {
      repo = $0
      opened.fulfill()
    }
    wait(for: [opened], timeout: 10)

    var failure: GitFailure??
    let done = expectation(description: "addWorktree")
    try XCTUnwrap(repo).addWorktree(
      path: fixture.worktreePath, base: "main", newBranch: "hang", track: false
    ) {
      failure = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)

    XCTAssertEqual(failure, .some(nil), "実体があるなら成功として返す")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: (fixture.worktreePath as NSString).appendingPathComponent(".git")),
      "前提: hook が返らなくても worktree は出来上がっている")
    XCTAssertTrue(
      GitRunner.shared.runSync(["status", "--porcelain"], cwd: fixture.worktreePath).isSuccess,
      "出来上がった worktree はそのまま使える")
  }

  /// 独立レーンでハングしている実行は、barrier を取る書き込みを巻き添えにしない。
  /// これが効かないと、1 本の worktree 作成や clone が以後の全 git 操作を止める。
  ///
  /// **打ち切りに助けられない形で測る。** アイドル上限が短い runner だと、ハングが自然に打ち切られた
  /// 後で書き込みが走って通ってしまい、レーン分離が効いていなくても緑になる。ハング側の上限は
  /// 十分長く（60 秒）取り、書き込みの期限をそれよりはるかに短く（3 秒）取る——排他はインスタンス内で
  /// 閉じるので、両方を同じ runner に通す必要がある。
  func testHangingIndependentLaneDoesNotBlockExclusiveWrites() throws {
    let runner = GitRunner(idleTimeout: 60)
    try fixture.installHook("pre-commit", script: fixture.waitingScript)
    try stageChange()
    let hangFinished = expectation(description: "hanging independent run")
    runner.run(["commit", "-m", "blocked"], cwd: fixture.root, lane: .independent) { _ in
      hangFinished.fulfill()
    }
    XCTAssertTrue(fixture.waitUntilHung(), "前提: 独立レーンの実行がハングしていること")

    let done = expectation(description: "exclusive write")
    runner.run(["config", "orbe.probe", "1"], cwd: fixture.root, lane: .exclusive) { _ in
      done.fulfill()
    }
    wait(for: [done], timeout: 3)

    fixture.release()  // ハングを解いて後片付け（解放し損ねると 60 秒居座る）
    wait(for: [hangFinished], timeout: 60)
  }

  /// `--progress` の進捗は `\r` 区切りで流れる（実測: 200 ファイルの clone で stderr 8.7KB・CR 204 個）。
  /// `\n` だけで行を割ると進捗と `fatal:` が 1 行に融合し、進捗の断片まみれの巨大な失敗理由が出る。
  func testFailureReasonSplitsProgressOnCarriageReturns() {
    let stderr = """
      Cloning into 'repo'...\n\
      remote: Enumerating objects: 202, done.\n\
      Receiving objects:  50% (101/202)\r\
      Receiving objects: 100% (202/202), 12.00 KiB | 12.00 MiB/s, done.\r\
      fatal: could not create work tree dir 'repo': Permission denied\n
      """

    let reason = GitRepo.essentialFailureReason(stderr)

    XCTAssertEqual(reason, "fatal: could not create work tree dir 'repo': Permission denied")
  }

  /// 実際の clone 失敗も同じ整形を通り、git の前口上を落として理由だけを返す。
  /// clone の stderr は成功・失敗どちらでも `Cloning into '<dest>'...` で始まるので、生の stderr を
  /// そのまま見せると、バナーが宛先パスまみれになって肝心の理由が埋もれる。
  func testCloneFailureReturnsOnlyTheEssentialReason() throws {
    // `ext::` は git が既定で拒否する。前口上を出した後に fatal を出す、ネットワーク不要の失敗。
    let url = "ext::\(try fixture.installScript("unused.sh", script: fixture.waitingScript))"
    var failure: GitFailure??
    let done = expectation(description: "clone")
    GitRepo.clone(url: url, dest: fixture.dir.appendingPathComponent("dst").path, runner: runner) {
      failure = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)

    guard case .message(let reason) = try XCTUnwrap(failure ?? nil) else {
      return XCTFail("git が理由を言っている失敗なので .message で返る")
    }
    XCTAssertTrue(reason.contains("fatal:"), "実質的な理由は残す: \(reason)")
    XCTAssertFalse(reason.contains("Cloning into"), "git の前口上は落とす: \(reason)")
    XCTAssertEqual(reason.split(separator: "\n").count, 1, "1 行の理由になる: \(reason)")
  }

  // MARK: - 正常経路（打ち切りの仕掛けが出力を取りこぼさないこと）

  /// 打ち切りのために読み取りを readabilityHandler へ移したので、正常終了の出力が
  /// 1 バイトも欠けないことを固定する（複数チャンクに割れる大きさで確かめる）。
  func testNormalRunCollectsCompleteOutput() throws {
    let line = String(repeating: "y", count: 120) + "\n"
    let body = String(repeating: line, count: 2000)  // 約 240KB＝pipe バッファを何度も跨ぐ
    try body.write(
      toFile: (fixture.root as NSString).appendingPathComponent("big.txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(fixture.git(["add", "-A"]).isSuccess)

    let output = GitRunner.shared.runSync(["diff", "--cached"], cwd: fixture.root)

    XCTAssertTrue(output.isSuccess)
    XCTAssertFalse(output.timedOut)
    XCTAssertEqual(
      output.stdoutText.components(separatedBy: "+" + line).count - 1, 2000,
      "追加行が 1 行も欠けない")
  }
}

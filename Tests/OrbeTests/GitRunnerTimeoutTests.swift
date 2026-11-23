import OrbeTestSupport
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
  /// 打ち切りを見る実行は、手で進める時計を渡した専用インスタンスで駆動する（`shared` のキューを一切汚さない）。本番の
  /// 無出力の上限は、時計を進めたときにだけ来る。arrange と後続確認は本番既定の `shared` で回す。
  private let clock = ManualClock()
  private lazy var runner = GitRunner(clock: clock.waits)
  private var fixture: GitHangFixture!

  override func setUpWithError() throws {
    fixture = try GitHangFixture()
  }

  // MARK: - ヘルパ

  /// 裏で走らせた `runSync` の結果。main で届く。
  private final class Pending {
    var output: GitRunner.Output?
  }

  /// `runSync` は同期なので背景で走らせる（時計を進める間、返らない実行にテストのスレッドを止めさせない）。
  private func start(_ args: [String], cwd: String? = nil) -> Pending {
    let pending = Pending()
    let dir = cwd ?? fixture.root
    DispatchQueue.global(qos: .userInitiated).async { [runner] in
      let output = runner.runSync(args, cwd: dir)
      DispatchQueue.main.async { pending.output = output }
    }
    return pending
  }

  /// 背景で走らせた `runSync` の結果を、期限つきで受ける（返らない実装でテストプロセスを固めない）。
  private func result(of pending: Pending, timeout: TimeInterval = 20) throws -> GitRunner.Output {
    pumpMain(until: { pending.output != nil }, timeout: timeout, "runSync が返る")
    return try XCTUnwrap(pending.output)
  }

  private func runSync(_ args: [String]) throws -> GitRunner.Output {
    try result(of: start(args))
  }

  /// 止まった実行を無出力の上限で切り、その結果を受ける。
  private func expireIdleLimit(of pending: Pending) throws -> GitRunner.Output {
    fixture.expireIdleLimit(on: clock, until: { pending.output != nil })
    return try result(of: pending)
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
    let filter = try fixture.installScript("hang-filter.sh", body: fixture.waitingBody)
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
    sleepUntil(timeout) { FileManager.default.fileExists(atPath: indexLockPath) }
  }

  /// 返らない `ext::` transport を相手にした clone。clone は hook を持たないので、止める手段は
  /// これだけ（`protocol.ext.allow` は既定で拒否なので、テストが明示的に開ける）。相手が止まったら、無出力の上限で切る。
  private func cloneFromHangingRemote() throws -> (output: GitRunner.Output, dest: String) {
    let helper = try fixture.installScript("hang-remote.sh", body: fixture.waitingBody)
    let dest = fixture.dir.appendingPathComponent("clone-dst").path
    let pending = start(
      ["-c", "protocol.ext.allow=always", "clone", "--progress", "ext::\(helper)", dest],
      cwd: fixture.dir.path)
    XCTAssertTrue(fixture.waitUntilHung(), "前提: 相手が止まっている")
    return (try expireIdleLimit(of: pending), dest)
  }

  // MARK: - 打ち切る / 打ち切らない

  /// 出力が流れている限り、最初の出力からの経過が上限を超えても打ち切らない。
  /// **アイドル方式であることの歯**——絶対時間で測る実装ならここが落ちる。
  func testStreamingCommandIsNotStopped() throws {
    try fixture.installHook("pre-commit", body: fixture.streamingBody)
    try stageChange()
    let pending = start(["commit", "-m", "slow but alive"])
    XCTAssertTrue(fixture.waitUntilHung(), "前提: hook が出力の合図を待っている")
    let hung = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline != nil }), "前提: 無出力の上限で眠っている")
    // 上限の長さは、眠った期限から読む（眠ってから時刻は進めていない）。
    let limit = try XCTUnwrap(hung.deadline) - clock.now

    XCTAssertEqual(clock.advance(by: limit * 3 / 4), 0, "前提: 上限の手前では起きない")
    let outputAt = clock.now
    let read = clock.readings
    fixture.tick()
    pumpMain(until: { self.clock.readings > read }, "hook の出力が届く")
    XCTAssertEqual(clock.advance(by: limit * 3 / 4), 1, "前提: 最初の期限は過ぎている")
    XCTAssertNotNil(
      clock.awaitSleeper(where: {
        $0.deadline.map { abs(($0 - outputAt) - limit) < 0.001 } ?? false
      }),
      "最後の出力から数え直した期限で眠り直す")

    fixture.release()
    let output = try result(of: pending)
    XCTAssertFalse(output.timedOut, "出力の後に上限が過ぎていないなら、最初からの経過が上限を超えても切ってはいけない")
    XCTAssertTrue(output.isSuccess, "完走した commit は成功する")
  }

  /// 無出力のまま止まった git は打ち切られ、`timedOut` で見分けられ、成功にはならない。打ち切った後、
  /// **孫プロセスが pipe の書き込み端を握っていても**、猶予で返る——`terminate()` のあと無期限に EOF を待つ実装だと
  /// ここで返らない。
  func testStoppedRunReturnsWhileGrandchildHoldsThePipes() throws {
    try fixture.installHook("pre-commit", body: fixture.pipeHoldingBody)
    try stageChange()
    let pending = start(["commit", "-m", "blocked"])
    XCTAssertTrue(fixture.waitUntilHung(), "前提: 孫が pipe を握ったまま、hook が止まっている")

    let grace = try XCTUnwrap(
      fixture.expireIdleLimitAwaitingGrace(on: clock), "打ち切りの後、猶予の期限で EOF を待つ")
    clock.advance(to: grace)
    let output = try result(of: pending)

    XCTAssertTrue(output.timedOut, "無出力のまま上限を過ぎたら打ち切る")
    XCTAssertFalse(output.isSuccess, "打ち切った実行を成功として扱ってはいけない")
    XCTAssertTrue(
      fixture.grandchildIsAlive(),
      "前提: 孫が pipe を握っていて EOF は来ていない（猶予で返った）")
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

    let pending = start(["add", "--", "big.big"])
    XCTAssertTrue(fixture.waitUntilHung(), "前提: clean フィルタがハングしている")
    XCTAssertTrue(
      waitForIndexLock(), "前提: このとき index.lock が握られている（偽ならこのテストは何も測らない）")

    XCTAssertTrue(try expireIdleLimit(of: pending).timedOut)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: indexLockPath),
      "SIGTERM を受けた git が lock を掃除する。残ると以後この repo への書き込みが全部 fatal になる")
    XCTAssertTrue(try runSync(["status", "--porcelain"]).isSuccess, "後続の git 操作が通る")
  }

  // MARK: - 打ち切り後の読み替えと、終わった実行の返り方

  /// post-checkout hook は worktree が出来上がった**後**に走る。hook が返らず打ち切っても
  /// worktree は完成しているので、**成功として返す**。失敗にすると、実在する worktree を指したまま
  /// 再実行が `fatal: a branch named 'x' already exists` で詰む——直した数より多く壊す。
  func testStoppedWorktreeAddSucceedsWhenTheWorktreeExists() throws {
    try fixture.installHook("post-checkout", body: fixture.waitingBody)
    var repo: GitRepo?
    let opened = expectation(description: "GitRepo.open")
    GitRepo.open(cwd: fixture.root, runner: runner) {
      repo = $0
      opened.fulfill()
    }
    wait(for: [opened], timeout: 10)

    var failure: GitFailure??
    try XCTUnwrap(repo).addWorktree(
      path: fixture.worktreePath, base: "main",
      newBranch: GitNewBranch(name: "hang", tracksBase: false)
    ) { failure = $0 }
    XCTAssertTrue(fixture.waitUntilHung(), "前提: post-checkout hook が止まっている")
    fixture.expireIdleLimit(on: clock, until: { failure != nil })

    XCTAssertEqual(failure, .some(nil), "実体があるなら成功として返す")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: (fixture.worktreePath as NSString).appendingPathComponent(".git")),
      "前提: hook が返らなくても worktree は出来上がっている")
    XCTAssertTrue(
      GitRunner.shared.runSync(["status", "--porcelain"], cwd: fixture.worktreePath).isSuccess,
      "出来上がった worktree はそのまま使える")
  }

  /// git が**自力で正常終了**したら、孫が pipe を握っていてもアイドル上限を待たずに返る。
  ///
  /// 待ちを EOF に賭けると、hook が背景へ投げたプロセス（`npm run dev &`・gpg-agent・言語サーバ）が
  /// 生きている限り EOF が来ないので、成功した実行が本番の無出力の上限を丸ごと待ち、根のサービスの書き込みなら
  /// その間ずっと同じ worktree の順番を占有する——打ち切り機構が解こうとした詰まりを、成功した実行で作り直す。
  /// 実行の完了を決めるのは**子の終了**であって EOF ではない、という契約をここで固定する。
  func testSuccessfulRunReturnsWhileGrandchildHoldsThePipes() throws {
    try fixture.installHook("pre-commit", body: fixture.daemonizingBody)
    try stageChange()
    let pending = start(["commit", "-m", "daemonizing hook"])
    XCTAssertTrue(fixture.waitUntilHung(), "前提: 孫が pipe を握ったまま、hook が止まっている")
    let idle = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline != nil })?.deadline, "前提: 無出力の上限で眠っている")

    fixture.release()
    let grace = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline.map { $0 < idle } ?? false })?.deadline,
      "git の終了の後、無出力の上限より手前の期限で EOF を待つ")
    clock.advance(to: grace)
    let output = try result(of: pending)

    XCTAssertTrue(output.isSuccess, "前提: hook は成功で返るので commit も成功する")
    XCTAssertFalse(output.timedOut, "打ち切っていない——終了後に EOF を諦めただけ")
    XCTAssertTrue(
      fixture.grandchildIsAlive(), "孫（テストの終わりまで生きる）の寿命に待ちを縛られない（EOF は来ていない）")
  }

  // MARK: - 失敗理由の整形（`--progress` を足したぶん）

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
    let url = "ext::\(try fixture.installScript("unused.sh", body: fixture.waitingBody))"
    var failure: GitFailure??
    GitRepo.clone(url: url, dest: fixture.dir.appendingPathComponent("dst").path, runner: runner) {
      failure = $0
    }
    pumpMain(until: { failure != nil }, timeout: 20, "clone が失敗で返る")

    guard case .reason(let reason) = try XCTUnwrap(failure ?? nil) else {
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

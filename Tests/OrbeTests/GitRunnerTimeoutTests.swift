import XCTest

@testable import Orbe

/// 無応答の git を打ち切る仕組みの検証。測るのは経過時間ではなく**無出力が続いた時間**——
/// 巨大リポジトリの clone のような正当な長時間実行を切らずに、認証待ち・hook のハング・
/// ネットワーク停止だけを切るには、測る対象がこれでなければならない。
///
/// ここが壊れると、返らない git を待つ UI が永久に固まる（打ち切りが効かない）か、
/// 進捗が流れているだけの正常な clone を途中で殺す（アイドル判定が壊れる）。
/// 打ち切った後に EOF を待ってしまう実装も同じく致命で、孫プロセス（hook・`git remote-ext`）が
/// pipe の書き込み端を握ったままなので、**切ったのに返らない**という同じハングを作り直す。
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

  /// 返らない `ext::` transport を相手にした clone（clone は hook を持たないので、
  /// 止める手段はこれだけ。git は `git remote-ext` → `sh` と孫を作るので、
  /// 「孫が pipe を握ったまま」も同時に再現できる）。
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

  /// 打ち切った commit は `.git/index.lock` を残さず、後続の git 操作がそのまま通る。
  func testStoppedCommitLeavesNoIndexLock() throws {
    try fixture.installHook("pre-commit", script: fixture.waitingScript)
    try stageChange()

    XCTAssertTrue(try runSync(["commit", "-m", "blocked"]).timedOut)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: (fixture.root as NSString).appendingPathComponent(".git/index.lock")),
      "lock が残ると、以後この repo への書き込みが全部 fatal になる")
    XCTAssertTrue(try runSync(["status", "--porcelain"]).isSuccess, "後続の git 操作が通る")
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

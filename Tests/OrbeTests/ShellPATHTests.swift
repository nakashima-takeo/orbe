import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 子プロセスへ渡す PATH の解決。純関数（検査・union）と、probe を差し替えた組み立て、
/// スタブシェルスクリプトによる subprocess 機構の検証を持つ。
/// 開発者の実ログインシェルは起こさない（probe を差し替えるか、スタブへ向ける）。
final class ShellPATHTests: OrbeTestCase {
  private var stubDir: URL!

  override func setUpWithError() throws {
    stubDir = TestScratch.caseDir
      .appendingPathComponent("ShellPATHTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
  }

  /// 模したい出力を出す実行可能スクリプト（`#!/bin/sh`。受け取った引数は `$@` で見られる）。
  private func stubShell(_ body: String) throws -> String {
    let url = stubDir.appendingPathComponent("shell-\(UUID().uuidString)")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }

  // MARK: - union（compose）

  /// 「起動には成功したが PATH が不完全」——欠けていた既知パスが末尾に補われる。
  func testComposeAppendsMissingKnownPaths() {
    XCTAssertEqual(
      ShellPATH.compose(login: "/usr/bin:/bin", known: ShellPATH.defaultKnownPaths),
      "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin")
  }

  func testComposeLeavesCompletePathUntouched() {
    let complete = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
    XCTAssertEqual(
      ShellPATH.compose(login: complete, known: ShellPATH.defaultKnownPaths), complete,
      "全て含むなら順序も含め変わらない")
  }

  /// 既知パスは「無いものを補う」役。ユーザーが意図した優先順は奪わない。
  func testComposeKeepsShellPriorityFirst() {
    let composed = ShellPATH.compose(
      login: "/Users/x/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin:/bin",
      known: ShellPATH.defaultKnownPaths)
    XCTAssertTrue(composed.hasPrefix("/Users/x/.local/share/mise/shims:"), "shim が先頭のまま")
  }

  func testComposeWithoutLoginPathIsKnownPathsOnly() {
    XCTAssertEqual(
      ShellPATH.compose(login: nil, known: ShellPATH.defaultKnownPaths),
      ShellPATH.defaultKnownPaths.joined(separator: ":"))
  }

  func testComposeDropsDuplicates() {
    XCTAssertEqual(
      ShellPATH.compose(login: "/usr/bin:/usr/bin:/bin", known: ShellPATH.defaultKnownPaths),
      "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin", "重複は初出だけ残す")
  }

  // MARK: - 妥当性検査（sanitize）

  func testSanitizeRejectsEmpty() {
    XCTAssertNil(ShellPATH.sanitize(nil))
    XCTAssertNil(ShellPATH.sanitize(""))
    XCTAssertNil(ShellPATH.sanitize("   \n "))
  }

  func testSanitizeDropsNonAbsoluteEntries() {
    XCTAssertEqual(ShellPATH.sanitize("relative/bin:/usr/bin"), "/usr/bin")
    XCTAssertNil(ShellPATH.sanitize("relative/bin:another"), "絶対パスが 1 つも残らなければ捨てる")
  }

  /// 改行が残っているのは env 出力の解析が PATH 行以外まで掴んだ＝壊れた値。
  func testSanitizeRejectsMultilineValue() {
    XCTAssertNil(ShellPATH.sanitize("PATH=/usr/bin\nSHLVL=1"))
  }

  func testSanitizeDropsEmptyEntries() {
    XCTAssertEqual(ShellPATH.sanitize("/usr/bin::/bin:"), "/usr/bin:/bin")
  }

  // MARK: - 組み立て（probe 差し替え）

  func testFailedProbeFallsBackToKnownPaths() {
    XCTAssertEqual(
      ShellPATH(probe: { nil }).value(), ShellPATH.knownPaths.joined(separator: ":"))
    XCTAssertEqual(
      ShellPATH(probe: { "garbage" }).value(), ShellPATH.knownPaths.joined(separator: ":"),
      "検査を通らない値は probe 失敗と同じ扱い")
  }

  /// ログインシェルの起動はプロセスで 1 回だけ。start() の連打にも同時 value() にも増えない。
  func testProbeRunsOncePerProcess() {
    let counter = CallCounter()
    let sut = ShellPATH(probe: {
      counter.increment()
      return "/usr/bin:/bin"
    })
    for _ in 0..<5 { sut.start() }
    DispatchQueue.concurrentPerform(iterations: 20) { _ in _ = sut.value() }
    XCTAssertEqual(counter.count, 1)
  }

  // MARK: - キャッシュ

  /// 起動クリティカルパスを塞がない要請。ディスクキャッシュがあれば probe の着地を待たない。
  func testDiskCacheAnswersWithoutWaitingForProbe() throws {
    AppStatePersistence.update { $0.cachedShellPath = "/opt/custom/bin:/usr/bin" }
    let clock = ManualClock()
    let blocked = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    let sut = ShellPATH(
      probe: {
        blocked.wait()  // 永久にブロックする probe（テスト終了時に解く）
        return nil
      }, clock: clock.waits)
    sut.start()
    let answer = value(of: sut)
    // main を回さずに待つ（`awaitSleeper(_:_:)` と同じ理由）。
    XCTAssertTrue(sleepUntil(10) { answer.isDone || !clock.sleepingDeadlines.isEmpty }, "返るか眠る")
    XCTAssertEqual(clock.sleepingDeadlines, [], "同期待ちへ落ちていない（時刻を進めずに返る）")
    XCTAssertTrue(answer.value?.hasPrefix("/opt/custom/bin:/usr/bin:") == true, "キャッシュ値が先頭に載る")
  }

  /// 永続するのは union 前の login PATH。knownPaths は Orbe の版で変わるので焼き込まない。
  func testProbeResultIsPersistedWithoutKnownPaths() {
    let sut = ShellPATH(probe: { "/opt/custom/bin:/usr/bin" })
    sut.start()
    XCTAssertTrue(
      waitForCachedShellPath { $0 == "/opt/custom/bin:/usr/bin" }, "既知パスは焼き込まれない")
  }

  /// probe の失敗でディスクキャッシュを壊さない。前回セッションが得た PATH は、次の起動が
  /// 既知パスだけから始まらないための安全網として残す。
  func testFailedProbeKeepsDiskCache() {
    nextTurn()  // 他テストが main に残した書き込みを処理し終えてから測る
    AppStatePersistence.update { $0.cachedShellPath = "/opt/custom/bin:/usr/bin" }
    let sut = ShellPATH(probe: { nil })
    sut.start()
    _ = sut.value()
    XCTAssertTrue(
      holds(for: 0.1) { AppStatePersistence.load()?.cachedShellPath == "/opt/custom/bin:/usr/bin" },
      "失敗した probe は保存を書き換えない")
  }

  /// 同期待ちの天井はプロセス全体で 1 つ。起動復元は agent タブの数だけ `value()` を呼ぶので、
  /// 呼び出しごとに配り直すとメインスレッドが止まる合計時間が掛け算になる。
  func testSyncWaitBudgetIsSharedAcrossCalls() {
    let clock = ManualClock()
    let blocked = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    let sut = ShellPATH(
      probe: {
        blocked.wait()  // 着地しない probe（テスト終了時に解く）
        return nil
      }, clock: clock.waits)
    sut.start()
    let floor = ShellPATH.knownPaths.joined(separator: ":")

    let first = value(of: sut)
    XCTAssertTrue(awaitSleeper(clock, clock.now + ShellPATH.syncWaitBudget), "最初の呼びは天井まで待つ")
    XCTAssertEqual(
      clock.advance(by: ShellPATH.syncWaitBudget + 1), 1,
      "天井まで進めると、待ち手を、進めた呼び出しの中で起こす。進めた呼び出しが戻った時点でこれが成り立たなくなったら、"
        + "testSettledWaitReturnsProbeResult が、天井では返らないことを確かめる時点（進めた直後）も成り立たない")
    pumpMain(until: { first.value != nil }, "天井で返る")
    XCTAssertEqual(first.value, floor)

    for _ in 0..<2 {
      let next = value(of: sut)
      pumpMain(until: { next.value != nil || !clock.sleepingDeadlines.isEmpty }, "返るか眠る")
      XCTAssertEqual(next.value, floor, "予算は呼び出しごとに配り直さない（眠らずに返る）")
      XCTAssertEqual(clock.sleepingDeadlines, [])
    }
  }

  /// 背景の検出は着地を待てる。打ち切って floor で答えると、その結果がセッションに焼き付く。
  func testSettledWaitReturnsProbeResult() {
    let clock = ManualClock()
    let released = DispatchSemaphore(value: 0)
    let sut = ShellPATH(
      probe: {
        released.wait()
        return "/opt/custom/bin:/usr/bin"
      }, clock: clock.waits)
    sut.start()

    let settled = value(of: sut, wait: .settled)
    XCTAssertTrue(awaitSleeper(clock, clock.now + ShellPATH.probeTimeout), "probe の上限で眠る")
    XCTAssertEqual(
      clock.advance(by: ShellPATH.syncWaitBudget + 1), 0, "同期待ちの天井を越えても起こさない")
    released.signal()
    pumpMain(until: { settled.value != nil }, "probe の着地で返る")
    XCTAssertTrue(
      settled.value?.hasPrefix("/opt/custom/bin:/usr/bin:") == true,
      "同期待ちの天井を越えても probe の着地を待つ")
  }

  func testUnchangedValueIsNotRewritten() throws {
    nextTurn()  // 他テストが main に残した書き込みを処理し終えてから測る
    AppStatePersistence.update { $0.cachedShellPath = "/opt/custom/bin:/usr/bin" }
    let url = try appStateFile()
    let before = try modificationDate(of: url)
    let sut = ShellPATH(probe: { "/opt/custom/bin:/usr/bin" })
    sut.start()
    _ = sut.value()
    // 書き込みは main へ投げられるので、main を回しながら変化が無いことを見る
    XCTAssertTrue(
      holds(for: 0.1) { (try? modificationDate(of: url)) == before }, "値が変わらないなら書き直さない")
  }

  // MARK: - probe の subprocess 機構（スタブシェル）

  func testProbeReadsPathFromEnvOutput() throws {
    let shell = try stubShell("echo HOME=/Users/test\necho PATH=/usr/bin:/bin\necho SHLVL=1")
    XCTAssertEqual(ShellPATH.probeLoginShell(shell: shell, timeout: 5), "/usr/bin:/bin")
  }

  /// rc が `PATH=` を echo するノイズより後に env の出力が来る。採るのは最後の行。
  func testProbeTakesLastPathLine() throws {
    let shell = try stubShell("echo PATH=/noise\necho PATH=/usr/bin:/bin")
    XCTAssertEqual(ShellPATH.probeLoginShell(shell: shell, timeout: 5), "/usr/bin:/bin")
  }

  func testProbeReturnsNilWhenNoPathLine() throws {
    let shell = try stubShell("echo SHLVL=1")
    XCTAssertNil(ShellPATH.probeLoginShell(shell: shell, timeout: 5))
  }

  /// 対話シェルは rc のエラーで非 0 終了しうる。PATH が出ていれば終了ステータスで捨てない。
  func testProbeAcceptsNonZeroExit() throws {
    let shell = try stubShell("echo PATH=/usr/bin:/bin\nexit 1")
    XCTAssertEqual(ShellPATH.probeLoginShell(shell: shell, timeout: 5), "/usr/bin:/bin")
  }

  /// login + interactive で起こす。`-i` を落とすと `.zshrc` を読まず、mise/asdf/nvm の shim を
  /// 丸ごと取りこぼす——「起動には成功したが PATH が不完全」という検出できない degrade になる。
  func testProbeStartsShellAsLoginInteractive() throws {
    let argsFile = stubDir.appendingPathComponent("args")
    let shell = try stubShell(
      "printf '%s\\n' \"$@\" > \"\(argsFile.path)\"\necho PATH=/usr/bin:/bin")
    XCTAssertEqual(ShellPATH.probeLoginShell(shell: shell, timeout: 5), "/usr/bin:/bin")
    XCTAssertEqual(
      try String(contentsOf: argsFile, encoding: .utf8), "-l\n-i\n-c\n/usr/bin/env\n")
  }

  /// rc が背景に残した孫プロセスが stdout を握ると EOF は二度と来ない。終わりを決めるのは
  /// **シェルの終了**なので、正しく出ている PATH を捨てて上限まで張り付くことはない。
  ///
  /// スタブは、PATH の行の後に、pipe の容量（最大 64KB）の 2 倍を超える行を書いてから終わる。書き終えるには、読み手が PATH の
  /// 行を含む塊を受け取り終えて、次の塊を読んでいる必要があるので、シェルが終わった時点で、PATH の行は届き終えている（汲み出しの
  /// 猶予を、時刻を進めて縮めても取りこぼさない）。孫は、スタブのディレクトリが消える（テストの終わり）まで生きる。
  func testProbeSucceedsWhenGrandchildHoldsStdout() throws {
    let clock = ManualClock()
    let grandchild = stubDir.appendingPathComponent("grandchild").path
    let shell = try stubShell(
      """
      end=$(( $(date +%s) + 60 ))
      (while [ -d "\(stubDir.path)" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 0.05; done) &
      echo $! > "\(grandchild).tmp" && mv "\(grandchild).tmp" "\(grandchild)"
      echo PATH=/usr/bin:/bin
      head -c 262144 /dev/zero | tr '\\0' x
      echo
      """)
    let probed = Probed()
    DispatchQueue.global().async {
      probed.set(ShellPATH.probeLoginShell(shell: shell, timeout: 10, clock: clock.waits))
    }
    let limit = clock.now + 10
    let drain = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline.map { $0 < limit } ?? false })?.deadline,
      "シェルの終了の後、上限より手前の期限（汲み出しの猶予）で眠る")
    clock.advance(to: drain)
    pumpMain(until: { probed.isDone }, "EOF を待ち続けない")
    XCTAssertEqual(probed.value, "/usr/bin:/bin")
    let pid = try XCTUnwrap(
      pid_t(
        try String(contentsOfFile: grandchild, encoding: .utf8).trimmingCharacters(
          in: .whitespacesAndNewlines)))
    XCTAssertEqual(kill(pid, 0), 0, "前提: 孫が stdout を握っていて EOF は来ていない（猶予で返った）")
  }

  /// 固まった rc は上限で打ち切る。上限を超えて待たない＝呼び出し元が張り付かない。
  func testProbeGivesUpAtTimeout() throws {
    let clock = ManualClock()
    let began = stubDir.appendingPathComponent("began").path
    let shell = try stubShell(": > \"\(began)\"\nsleep 30")
    let probed = Probed()
    DispatchQueue.global().async {
      probed.set(ShellPATH.probeLoginShell(shell: shell, timeout: 1, clock: clock.waits))
    }
    pumpMain(until: { FileManager.default.fileExists(atPath: began) }, "前提: シェルが固まっている")
    let deadline = clock.now + 1
    XCTAssertNotNil(clock.awaitSleeper(until: deadline), "上限の期限で眠る")
    clock.advance(to: deadline)
    pumpMain(until: { probed.isDone }, "上限で戻る")
    XCTAssertNil(probed.value)
  }

  // MARK: - ヘルパ

  /// probe の着地は main への非同期書き込みを伴うので、条件が満たされるまで RunLoop を回す。
  private func waitForCachedShellPath(_ matches: (String?) -> Bool) -> Bool {
    waitUntil(2) { matches(AppStatePersistence.load()?.cachedShellPath) }
  }

  /// 裏の `value(wait:)` が、`deadline` で眠るまで待つ。main を回さずに待つ——ほかのテストが main に残した保存の書き込みが、
  /// 裏の呼び出しがディスクのキャッシュを読む前に、このテストの保存先へ書かれると、呼び出しが probe を待たずに返る。
  private func awaitSleeper(_ clock: ManualClock, _ deadline: WaitClock.Instant) -> Bool {
    sleepUntil(10) { clock.sleepingDeadlines.contains(deadline) }
  }

  /// 裏のスレッドで `value(wait:)` を呼ぶ（手で進める時計の上で眠る呼び出しに、テストのスレッドを止めさせない）。
  private func value(of sut: ShellPATH, wait: ShellPATH.Wait = .bounded) -> Probed {
    let probed = Probed()
    DispatchQueue.global().async { probed.set(sut.value(wait: wait)) }
    return probed
  }

  private func modificationDate(of url: URL) throws -> Date? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
  }
}

/// 裏のスレッドで得た PATH。
private final class Probed: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private var stored: String?
  func set(_ value: String?) {
    lock.withLock {
      done = true
      stored = value
    }
  }
  var isDone: Bool { lock.withLock { done } }
  var value: String? { lock.withLock { stored } }
}

/// 並行に呼ばれる probe の回数を数える。
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

import Foundation
import XCTest

@testable import Orbe

/// 子プロセスへ渡す PATH の解決。純関数（検査・union）と、probe を差し替えた組み立て、
/// スタブシェルスクリプトによる subprocess 機構の検証を持つ。
/// 開発者の実ログインシェルは起こさない（probe を差し替えるか、スタブへ向ける）。
final class ShellPATHTests: OrbeTestCase {
  private var stubDir: URL!

  override func setUpWithError() throws {
    stubDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ShellPATHTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: stubDir)
  }

  /// 引数（`-l -i -c /usr/bin/env`）を無視して、模したい出力だけを出す実行可能スクリプト。
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
      ShellPATH.compose(login: "/usr/bin:/bin"),
      "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin")
  }

  func testComposeLeavesCompletePathUntouched() {
    let complete = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
    XCTAssertEqual(ShellPATH.compose(login: complete), complete, "全て含むなら順序も含め変わらない")
  }

  /// 既知パスは「無いものを補う」役。ユーザーが意図した優先順は奪わない。
  func testComposeKeepsShellPriorityFirst() {
    let composed = ShellPATH.compose(
      login: "/Users/x/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin:/bin")
    XCTAssertTrue(composed.hasPrefix("/Users/x/.local/share/mise/shims:"), "shim が先頭のまま")
  }

  func testComposeWithoutLoginPathIsKnownPathsOnly() {
    XCTAssertEqual(ShellPATH.compose(login: nil), ShellPATH.knownPaths.joined(separator: ":"))
  }

  func testComposeDropsDuplicates() {
    XCTAssertEqual(
      ShellPATH.compose(login: "/usr/bin:/usr/bin:/bin"),
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

  /// 区切りを失った連結（`printf %s "$PATH"` が fish で返しうる形）は構造検査では弾けない。
  /// 弾けなくても害が無いことを担保するのは union の側——既知パスは必ず載る。
  func testUnseparatedGarbageStillYieldsUsablePath() {
    let garbage = "/usr/bin/opt/homebrew/bin/usr/local/bin"
    XCTAssertEqual(ShellPATH.sanitize(garbage), garbage, "1 要素として通る")
    XCTAssertTrue(ShellPATH.compose(login: garbage).contains("/opt/homebrew/bin"))
  }

  // MARK: - 組み立て（probe 差し替え）

  func testIncompleteProbeResultIsCompletedByKnownPaths() {
    let sut = ShellPATH(probe: { "/usr/bin:/bin" })
    XCTAssertEqual(sut.value(), "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin")
  }

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
    let blocked = DispatchSemaphore(value: 0)
    let sut = ShellPATH(probe: {
      blocked.wait()  // 永久にブロックする probe（テスト終了時に解く）
      return nil
    })
    sut.start()
    let started = Date()
    XCTAssertTrue(sut.value().hasPrefix("/opt/custom/bin:/usr/bin:"), "キャッシュ値が先頭に載る")
    XCTAssertLessThan(
      Date().timeIntervalSince(started), ShellPATH.syncWaitBudget, "同期待ちへ落ちていない")
    blocked.signal()
  }

  /// 永続するのは union 前の login PATH。knownPaths は Orbe の版で変わるので焼き込まない。
  func testProbeResultIsPersistedWithoutKnownPaths() {
    let sut = ShellPATH(probe: { "/opt/custom/bin:/usr/bin" })
    sut.start()
    XCTAssertTrue(
      waitForCachedShellPath { $0 == "/opt/custom/bin:/usr/bin" }, "既知パスは焼き込まれない")
  }

  func testUnchangedValueIsNotRewritten() throws {
    drainMain()  // 他テストが残した main 上の書き込みを流し切ってから測る
    AppStatePersistence.update { $0.cachedShellPath = "/opt/custom/bin:/usr/bin" }
    let url = try appStateFile()
    let before = try modificationDate(of: url)
    let sut = ShellPATH(probe: { "/opt/custom/bin:/usr/bin" })
    sut.start()
    _ = sut.value()
    drainMain()  // 書き込みは main へ投げられるので、走る機会を与えてから変化が無いことを見る
    XCTAssertEqual(try modificationDate(of: url), before, "値が変わらないなら書き直さない")
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

  /// 固まった rc は上限で打ち切る。上限を超えて待たない＝呼び出し元が張り付かない。
  func testProbeGivesUpAtTimeout() throws {
    let shell = try stubShell("sleep 30")
    let started = Date()
    XCTAssertNil(ShellPATH.probeLoginShell(shell: shell, timeout: 1))
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "上限で戻る")
  }

  // MARK: - ヘルパ

  /// probe の着地は main への非同期書き込みを伴うので、条件が満たされるまで RunLoop を回す。
  private func waitForCachedShellPath(_ matches: (String?) -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if matches(AppStatePersistence.load()?.cachedShellPath) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return false
  }

  private func drainMain() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }

  private func modificationDate(of url: URL) throws -> Date? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
  }
}

/// 並行に呼ばれる probe の回数を数える。
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

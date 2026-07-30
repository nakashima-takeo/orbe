import XCTest

/// 状態報告シム（`app/agent-plugin/.../hooks/orbe-agent-status.sh`）のチャネルゲートを実 `/bin/sh` で
/// 機械検証する。dev / release の plugin は別名の別枠として両方 enabled になるため、シムは自分の
/// 実体化コピーに刻まれた bundle ID とペインが名乗る `ORBE_BUNDLE_ID` が一致する呼び出しにだけ応える。
/// テストは同梱物でなくリポジトリ実体のプラグインを temp へ複製して走らせる（`CompletionShimTests` と同じ形）。
/// 呼び方は claude / codex の絶対パス呼びと agy の相対呼び（cwd＝プラグインルート）の両方を突く。
final class AgentShimChannelGateTests: XCTestCase {
  /// リポジトリ実体のプラグインルート。このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  private static let sourcePluginRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OrbeTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("app/agent-plugin/plugins/orbe-agent")

  /// シムが委譲したかどうかと、委譲先へ渡った引数・stdin。
  private struct Result {
    let exitCode: Int32
    let delegated: String?  // fake orbe-report の記録（委譲されなければ nil）
  }

  private var work: URL!  // このテスト専用の作業ディレクトリ
  private var pluginRoot: URL!  // 複製したプラグインルート（hooks/channel を置く先）
  private var reportBin: URL!  // 引数と stdin を記録する fake orbe-report
  private var reportLog: URL!

  override func setUpWithError() throws {
    work = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AgentShimChannelGateTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    pluginRoot = work.appendingPathComponent("plugin")
    try FileManager.default.copyItem(at: Self.sourcePluginRoot, to: pluginRoot)
    reportLog = work.appendingPathComponent("report.log")
    reportBin = work.appendingPathComponent("orbe-report")
    let script = """
      #!/bin/sh
      { echo "args:$*"; echo "stdin:$(cat)"; } > "\(reportLog.path)"
      """
    try Data(script.utf8).write(to: reportBin)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: reportBin.path)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: work)
  }

  /// `hooks/channel`（実体化時に Orbe が刻む bundle ID）を置く。
  private func writeChannel(_ bundleId: String) throws {
    try Data("\(bundleId)\n".utf8)
      .write(to: pluginRoot.appendingPathComponent("hooks/channel"))
  }

  /// シムを実 `/bin/sh` で起こす。`relative` は agy 形式（cwd＝プラグインルートからの相対呼び）。
  /// env は明示辞書のみ（継承しない）。stdin には hook JSON を流す。
  private func runShim(
    bundleId: String?, withReportBin: Bool = true, relative: Bool = false
  ) throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    let shim =
      relative
      ? "./hooks/orbe-agent-status.sh"
      : pluginRoot.appendingPathComponent("hooks/orbe-agent-status.sh").path
    process.arguments = [shim, "claude", "working"]
    process.currentDirectoryURL = pluginRoot
    var env = ["PATH": "/usr/bin:/bin"]
    if withReportBin { env["ORBE_REPORT_BIN"] = reportBin.path }
    if let bundleId { env["ORBE_BUNDLE_ID"] = bundleId }
    process.environment = env
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    stdin.fileHandleForWriting.write(Data(#"{"session_id":"s1"}"#.utf8))
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    return Result(
      exitCode: process.terminationStatus,
      delegated: try? String(contentsOf: reportLog, encoding: .utf8))
  }

  /// Orbe 外の端末（`ORBE_REPORT_BIN` 無し）では何もしない。
  func testWithoutReportBinaryDoesNotDelegate() throws {
    try writeChannel("dev.orbe.app.dev")
    let result = try runShim(bundleId: "dev.orbe.app.dev", withReportBin: false)
    XCTAssertNil(result.delegated)
    XCTAssertEqual(result.exitCode, 0)
  }

  /// 自チャネルのペインからの呼び出しは委譲し、引数と stdin（hook JSON）が透過する。
  func testMatchingChannelDelegatesWithArgumentsAndStdin() throws {
    try writeChannel("dev.orbe.app.dev")
    let result = try runShim(bundleId: "dev.orbe.app.dev")
    XCTAssertEqual(result.exitCode, 0)
    let delegated = try XCTUnwrap(result.delegated)
    XCTAssertTrue(delegated.contains("args:claude working"), delegated)
    XCTAssertTrue(delegated.contains(#"stdin:{"session_id":"s1"}"#), delegated)
  }

  /// 他チャネルのペインからの呼び出しは黙って落とす（release の枠が dev のペインを追わない）。
  func testMismatchedChannelDoesNotDelegate() throws {
    try writeChannel("dev.orbe.app")
    let result = try runShim(bundleId: "dev.orbe.app.dev")
    XCTAssertNil(result.delegated)
    XCTAssertEqual(result.exitCode, 0)
  }

  /// agy 形式（cwd＝ステージ済みプラグインルートからの相対呼び）でも channel に届く。
  func testMatchingChannelDelegatesOnRelativeInvocation() throws {
    try writeChannel("dev.orbe.app.dev")
    let result = try runShim(bundleId: "dev.orbe.app.dev", relative: true)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertNotNil(result.delegated)
  }

  func testMismatchedChannelDoesNotDelegateOnRelativeInvocation() throws {
    try writeChannel("dev.orbe.app")
    let result = try runShim(bundleId: "dev.orbe.app.dev", relative: true)
    XCTAssertNil(result.delegated)
    XCTAssertEqual(result.exitCode, 0)
  }

  /// channel が無い（実体化を通っていないコピー）なら通す＝状態追跡を黙って殺さない。
  func testMissingChannelDelegates() throws {
    let result = try runShim(bundleId: "dev.orbe.app.dev")
    XCTAssertNotNil(result.delegated)
  }

  /// ペインが `ORBE_BUNDLE_ID` を名乗らない（旧リリース版の Orbe）なら通す＝同じく fail-open。
  func testMissingBundleIdDelegates() throws {
    try writeChannel("dev.orbe.app.dev")
    let result = try runShim(bundleId: nil)
    XCTAssertNotNil(result.delegated)
  }
}

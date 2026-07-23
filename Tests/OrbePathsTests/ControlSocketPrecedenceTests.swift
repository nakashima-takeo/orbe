import XCTest

@testable import OrbePaths

/// control.sock 解決の優先順（明示 `ORBE_STATE_DIR` ＞ 暗黙 `ORBE_SOCK`）を固定する。
/// 実 Orbe のペイン内から隔離インスタンスを操作するとき、継承 `ORBE_SOCK` に
/// 引きずられて実 Orbe へ届かないことの回帰テスト（Issue #2）。
final class ControlSocketPrecedenceTests: XCTestCase {
  private var stateDir: URL!

  override func setUpWithError() throws {
    stateDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-paths-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: stateDir)
  }

  /// ORBE_STATE_DIR（明示）と ORBE_SOCK（暗黙）の両方があるとき、明示が勝つ。
  func testStateDirWinsOverInheritedSock() {
    let env = [
      OrbePaths.stateDirEnvVar: stateDir.path,
      OrbePaths.sockEnvVar: "/tmp/other-instance/control.sock",
    ]
    XCTAssertEqual(
      OrbePaths.controlSocketPath(env: env),
      stateDir.appendingPathComponent("control.sock", isDirectory: false).path
    )
  }

  /// ORBE_STATE_DIR 未設定なら ORBE_SOCK（ペイン注入の実パス）をそのまま使う。
  func testSockUsedWhenStateDirUnset() {
    let env = [OrbePaths.sockEnvVar: "/tmp/injected/control.sock"]
    XCTAssertEqual(OrbePaths.controlSocketPath(env: env), "/tmp/injected/control.sock")
  }
}

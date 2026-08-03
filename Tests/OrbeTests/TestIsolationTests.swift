import Foundation
import OrbePaths
import XCTest

@testable import Orbe

/// 隔離ハーネス（`TestIsolation`）が実際に何を立てたかを固定する。
///
/// ここが崩れると、他の全テストが静かに開発者の実環境——実 `workspaces.json`・
/// ghostty の user 設定・実 state dir——を読み書きし始める。テストは手元で緑のまま、
/// 中身は「開発者のマシンの状態」を測るものへ変質し、CI と挙動が食い違う。
final class TestIsolationTests: OrbeTestCase {

  /// state dir は temp 配下で、`<root>/control.sock` が AF_UNIX の上限に収まる長さ。
  func testStateDirIsIsolatedAndShortEnough() throws {
    let stateDir = try XCTUnwrap(ProcessInfo.processInfo.environment[OrbePaths.stateDirEnvVar])
    XCTAssertEqual(stateDir, TestIsolation.root.path, "ORBE_STATE_DIR は隔離根を指す")
    XCTAssertTrue(
      stateDir.hasPrefix(NSTemporaryDirectory()), "隔離根は temp 配下（実 state dir ではない）")
    XCTAssertLessThanOrEqual(
      stateDir.utf8.count, TestIsolation.maxRootPathBytes, "sun_path 104 バイト上限に収まる長さ")
  }

  /// 制御ソケットは隔離根の下。空だと制御 API が無言で無効化するので、非空であることも見る。
  func testControlSocketPointsIntoIsolatedRoot() {
    let path = ControlServer.shared.socketPath
    XCTAssertFalse(path.isEmpty, "空＝制御 API 無効。ハーネスがパス長を超えさせている")
    XCTAssertEqual(path, TestIsolation.root.appendingPathComponent("control.sock").path)
    XCTAssertLessThan(path.utf8.count, 104, "AF_UNIX の sun_path 上限")
  }

  /// 同梱リソースの探索根は管理下の空ディレクトリ（既定の Xcode bin ではない）。
  func testBundledResourcesRootIsManaged() throws {
    let root = try XCTUnwrap(BundledResources.root)
    XCTAssertEqual(root.path, TestIsolation.root.appendingPathComponent("resources").path)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path), [], "層1 の既定 conf も不在")
  }

  /// 永続 4 種はテスト 1 件ごとの専用ディレクトリを指す（テスト間で状態が漏れない）。
  func testPerCaseOverridesPointIntoCaseDir() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    XCTAssertEqual(dir.deletingLastPathComponent().path, TestIsolation.root.path)
    for url in [
      WorkspacePersistence.fileURLOverride, SettingsPersistence.fileURLOverride,
      AppStatePersistence.fileURLOverride, GuiConfig.fileURLOverride,
    ] {
      let url = try XCTUnwrap(url, "per-test の override が張られていない")
      XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
    }
  }

  /// ghostty の user 層は不在ファイルへ向く＝実 user 設定は読まれない。
  func testGhosttyUserLayerIsAbsent() throws {
    let url = try XCTUnwrap(Config.userFileURLOverride)
    XCTAssertEqual(url.path, TestIsolation.root.appendingPathComponent("ghostty-user.conf").path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "user 層は不在＝読まれない")
  }

  /// 補完の学習ストアは root 直下に固定する（`shared` が初回タッチで焼くため per-test にできない）。
  func testCompletionLearningIsProcessWide() throws {
    let url = try XCTUnwrap(CompletionLearning.fileURLOverride)
    XCTAssertEqual(
      url.path, TestIsolation.root.appendingPathComponent("completion-learning.json").path)
  }
}

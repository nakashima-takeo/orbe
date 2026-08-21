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
  ///
  /// caseDir の下であることが要点——root 直下だと、テストが同梱物を組んだ中身が `endCase` の
  /// 削除に乗らず以降の全テストへ残る（向き先だけ張り直しても中身は消えない）。
  func testBundledResourcesRootIsManaged() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let root = try XCTUnwrap(BundledResources.root)
    XCTAssertEqual(root.path, dir.appendingPathComponent("resources").path)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path), [], "層1 の既定 conf も不在")
  }

  /// テスト 1 件ごとの専用ディレクトリを指す override 群（テスト間で状態が漏れない）。
  /// テストが自分で書き換えても `beginCase` が毎回張り直すので、戻し忘れが次へ漏れない。
  ///
  /// `stablePluginDirOverride` が外れると、`WindowController()` の起動同期
  /// （`materializeStablePlugin`）が `ORBE_STATE_DIR` を見ずに実ホームの application support を
  /// 書き換える——テストは緑のまま開発機と CI のホームが汚れる。
  func testPerCaseOverridesPointIntoCaseDir() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    XCTAssertEqual(dir.deletingLastPathComponent().path, TestIsolation.root.path)
    for url in [
      WorkspacePersistence.fileURLOverride, SettingsPersistence.fileURLOverride,
      AppStatePersistence.fileURLOverride, GuiConfig.fileURLOverride,
      AgentPluginInstaller.stablePluginDirOverride, BundledResources.root,
      CustomSoundStore.directoryURLOverride,
    ] {
      let url = try XCTUnwrap(url, "per-test の override が張られていない")
      XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
    }
  }

  /// ghostty の user 層は caseDir 配下の不在ファイルへ向く＝実 user 設定は読まれない。
  /// テストが層を立てるならここへ書くので、書いた中身が `endCase` の削除に乗る位置に居る必要がある。
  func testGhosttyUserLayerIsAbsent() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let url = try XCTUnwrap(Config.userFileURLOverride)
    XCTAssertEqual(url.path, dir.appendingPathComponent("ghostty-user.conf").path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "user 層は不在＝読まれない")
  }

  /// テスト 1 件ごとに別の作業ディレクトリが配られ、前のテストのものは消えている。
  ///
  /// `testPerCaseOverridesPointIntoCaseDir` は override の向き先しか見ないので、全テストが
  /// 同じディレクトリを共有していても通ってしまう。配り直し（別パス）と後始末（前のパスが不在）は
  /// ここでしか測れない。両方が崩れると、前のテストが書いた永続を次のテストが読む。
  func testCaseDirIsFreshForEachTest() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let previous = try XCTUnwrap(TestIsolation.previousCaseDir, "直前のテストへ配った記録が無い")
    XCTAssertNotEqual(dir.path, previous.path, "前のテストと同じディレクトリを使い回している")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: previous.path),
      "前のテストのディレクトリが残っている＝後始末が効いていない")
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["resources"],
      "配られた直後のディレクトリは、ハーネスが用意する空の同梱リソース根だけを持つ")
  }

  /// 補完の学習ストアは root 直下に固定する（`shared` が初回タッチで焼くため per-test にできない）。
  /// ＝この 1 種だけは学習状態がテスト間で持ち越される。
  func testCompletionLearningIsProcessWide() throws {
    let url = try XCTUnwrap(CompletionLearning.fileURLOverride)
    XCTAssertEqual(
      url.path, TestIsolation.root.appendingPathComponent("completion-learning.json").path)
  }
}

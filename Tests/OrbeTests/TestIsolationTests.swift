import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 隔離ハーネス（`TestIsolation`）が実際に何を立てたかを固定する。
///
/// ここが崩れると、他の全テストが静かに開発者の実環境——実 `workspaces.json`・
/// ghostty の user 設定・実 state dir——を読み書きし始める。テストは手元で緑のまま、
/// 中身は「開発者のマシンの状態」を測るものへ変質し、CI と挙動が食い違う。
final class TestIsolationTests: OrbeTestCase {

  /// 端末のクリップボードはシステム全域の general ではなく、テストごとの一意名の pasteboard。
  /// 外れると `swift test` のたびに開発者のクリップボードが置き換わり、履歴アプリへ流れる。
  func testTerminalPasteboardIsNotTheGeneralPasteboard() {
    XCTAssertNotEqual(Ghostty.pasteboard.name, NSPasteboard.general.name)
  }

  /// 同梱リソースの探索根は管理下の空ディレクトリ（既定の Xcode bin ではない）。
  ///
  /// caseDir の下であることが要点——根の直下だと、テストが同梱物を組んだ中身がテスト終了の
  /// 削除に乗らず以降の全テストへ残る（向き先だけ張り直しても中身は消えない）。
  func testBundledResourcesRootIsManaged() throws {
    let dir = TestScratch.caseDir
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
    let dir = TestScratch.caseDir
    XCTAssertEqual(dir.deletingLastPathComponent().path, TestIsolation.stateDir.path)
    for url in [
      WorkspacePersistence.fileURLOverride, SettingsPersistence.fileURLOverride,
      AppStatePersistence.fileURLOverride, GuiConfig.fileURLOverride,
      AgentPluginInstaller.stablePluginDirOverride, BundledResources.root,
      CustomSoundStore.directoryURLOverride, TaskPersistence.fileURLOverride,
      AgentSessionLog.fileURLOverride, Config.userFileURLOverride,
    ] {
      let url = try XCTUnwrap(url, "per-test の override が張られていない")
      XCTAssertEqual(url.deletingLastPathComponent().path, dir.path)
    }
    // ghostty の user 層は不在ファイル＝開発者の実 user 設定は読まれない。
    let ghosttyUser = try XCTUnwrap(Config.userFileURLOverride)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ghosttyUser.path), "user 層は不在＝読まれない")
  }

  /// テスト 1 件ごとに別の作業ディレクトリが配られ、前のテストのものは消えている。
  ///
  /// `testPerCaseOverridesPointIntoCaseDir` は override の向き先しか見ないので、全テストが
  /// 同じディレクトリを共有していても通ってしまう。配り直し（別パス）と後始末（前のパスが不在）は
  /// ここでしか測れない。両方が崩れると、前のテストが書いた永続を次のテストが読む。
  func testCaseDirIsFreshForEachTest() throws {
    let dir = TestScratch.caseDir
    let previous = try XCTUnwrap(TestScratch.previousCaseDir, "直前のテストへ配った記録が無い")
    XCTAssertNotEqual(dir.path, previous.path, "前のテストと同じディレクトリを使い回している")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: previous.path),
      "前のテストのディレクトリが残っている＝後始末が効いていない")
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["resources"],
      "配られた直後のディレクトリは、ハーネスが用意する空の同梱リソース根だけを持つ")
  }
}

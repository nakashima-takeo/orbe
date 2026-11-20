import AppKit
import XCTest

@testable import Orbe

/// Home のフォルダの用意を固定する。Orbe の操作の指示は UI 言語の雛形へ毎回書き直し、CLAUDE.md は無いフォルダを
/// 作るときだけ置いて以後は触らない。用意は UI 言語が確定した時点で行う——新規利用者は初回の言語選択を確定するまで作らない。
///
/// 壊れると何が起きるか: 人や AI が書き換えた CLAUDE.md が起動のたびに雛形へ戻される。Orbe の操作の指示の改版が既存の
/// 利用者に届かない。言語選択の前に作ると、選んだ言語と違う雛形が置かれる。隔離起動で隔離先を使わないと、検証用の
/// インスタンスが本物の Home の指示を書き換え、本物の Home にタスクの作業場を作る。
final class HomeFolderTests: OrbeTestCase {
  private var folder: URL { HomeFolder.url }
  private var claudeMd: URL { folder.appendingPathComponent("CLAUDE.md") }
  private var rules: URL { folder.appendingPathComponent(HomeFolder.rulesPath) }

  private func contents(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  /// Orbe の操作の指示は毎回今の雛形へ戻し、CLAUDE.md は書き換えを上書きせず、消しても戻さない。
  func testPrepareRewritesRulesButLeavesClaudeMdToPeople() throws {
    HomeFolder.prepare(language: .ja)
    try "edited".write(to: claudeMd, atomically: true, encoding: .utf8)
    try "stale".write(to: rules, atomically: true, encoding: .utf8)

    HomeFolder.prepare(language: .en)
    XCTAssertEqual(try contents(claudeMd), "edited")
    XCTAssertEqual(try contents(rules), HomeTemplate.rules(.en, home: folder.path))

    try FileManager.default.removeItem(at: claudeMd)
    try FileManager.default.removeItem(at: rules)
    HomeFolder.prepare(language: .ja)
    XCTAssertFalse(FileManager.default.fileExists(atPath: claudeMd.path))
    XCTAssertEqual(try contents(rules), HomeTemplate.rules(.ja, home: folder.path))
  }

  func testReturningUserGetsTheFolderAtLaunchAndTheHomePointsAtIt() throws {
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    let wc = WindowController()

    XCTAssertEqual(try contents(claudeMd), HomeTemplate.claudeMd(.ja))
    XCTAssertEqual(try contents(rules), HomeTemplate.rules(.ja, home: folder.path))
    XCTAssertEqual(try XCTUnwrap(wc.workspaces.last).rootPath, folder.path)
  }

  /// OS の言語と違う言語を選ぶ——OS の言語で作る誤りを、どの言語の環境でも検出するため。
  func testNewUserGetsTheFolderOnlyAfterChoosingALanguage() throws {
    let chosen: Language = Language.systemDefault == .ja ? .en : .ja
    let wc = WindowController()
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "言語選択の前には作らない")

    let gate = try XCTUnwrap(wc.model.languageSelect)
    gate.selected = try XCTUnwrap(Language.allCases.firstIndex(of: chosen))
    gate.activate()

    XCTAssertEqual(try contents(claudeMd), HomeTemplate.claudeMd(chosen), "選んだ言語の雛形")
    XCTAssertEqual(
      try contents(rules), HomeTemplate.rules(chosen, home: folder.path), "選んだ言語の雛形")
  }

  /// 隔離起動の Home は隔離先の state フォルダの `home/` で、チャネルごとの本物のフォルダではない。
  func testAnIsolatedInstanceKeepsHomeInsideItsStateDir() {
    HomeFolder.urlOverride = nil

    XCTAssertEqual(
      HomeFolder.url.standardizedFileURL.path,
      TestIsolation.stateDir.appendingPathComponent("home").standardizedFileURL.path)
  }
}

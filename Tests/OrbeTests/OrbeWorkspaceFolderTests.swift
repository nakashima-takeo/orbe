import AppKit
import XCTest

@testable import Orbe

/// Orbe の workspace のフォルダの用意を固定する。無ければ UI 言語の雛形入りで作り、あれば中身に触らない。
/// 用意は UI 言語が確定した時点——新規利用者は初回の言語選択を確定するまで作らない。
///
/// 壊れると何が起きるか: 人や AI が書き換えた CLAUDE.md が起動のたびに雛形へ戻される。言語選択の前に作ると、
/// 選んだ言語と違う雛形が置かれ、以後は作り直されないまま残る。
final class OrbeWorkspaceFolderTests: OrbeTestCase {
  private func folder() throws -> URL { try XCTUnwrap(OrbeWorkspaceFolder.url) }
  private func claudeMd() throws -> URL { try folder().appendingPathComponent("CLAUDE.md") }

  /// あれば触らない——書き換えた CLAUDE.md は上書きせず、CLAUDE.md だけ消しても戻さない。
  func testPrepareLeavesAnExistingFolderUntouched() throws {
    OrbeWorkspaceFolder.prepare(language: .ja)
    try "edited".write(to: claudeMd(), atomically: true, encoding: .utf8)
    OrbeWorkspaceFolder.prepare(language: .en)
    XCTAssertEqual(try String(contentsOf: claudeMd(), encoding: .utf8), "edited")

    try FileManager.default.removeItem(at: claudeMd())
    OrbeWorkspaceFolder.prepare(language: .ja)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try claudeMd().path))
  }

  func testReturningUserGetsTheFolderAtLaunchAndTheOrbeWorkspacePointsAtIt() throws {
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    let wc = WindowController()

    XCTAssertEqual(
      try String(contentsOf: claudeMd(), encoding: .utf8), OrbeWorkspaceTemplate.claudeMd(.ja))
    XCTAssertEqual(try XCTUnwrap(wc.workspaces.last).rootPath, try folder().path)
  }

  /// OS の言語と違う言語を選ぶ——OS の言語で作る誤りを、どの言語の環境でも落とすため。
  func testNewUserGetsTheFolderOnlyAfterChoosingALanguage() throws {
    let chosen: Language = Language.systemDefault == .ja ? .en : .ja
    let wc = WindowController()
    XCTAssertFalse(FileManager.default.fileExists(atPath: try folder().path), "言語選択の前には作らない")

    let gate = try XCTUnwrap(wc.model.languageSelect)
    gate.selected = try XCTUnwrap(Language.allCases.firstIndex(of: chosen))
    gate.activate()

    XCTAssertEqual(
      try String(contentsOf: claudeMd(), encoding: .utf8), OrbeWorkspaceTemplate.claudeMd(chosen),
      "選んだ言語の雛形")
  }
}

import AppKit
import XCTest

@testable import Orbe

/// Orbe の workspace のフォルダの用意を固定する。無ければ UI 言語の雛形入りで作り、あれば中身に触らない。
/// 用意は UI 言語が確定した時点——新規利用者は初回の言語選択を確定するまで作らない。
final class OrbeWorkspaceFolderTests: OrbeTestCase {
  private func folder() throws -> URL { try XCTUnwrap(OrbeWorkspaceFolder.url) }
  private func claudeMd() throws -> URL { try folder().appendingPathComponent("CLAUDE.md") }

  func testPrepareCreatesTheFolderWithTheTemplateOfTheLanguage() throws {
    OrbeWorkspaceFolder.prepare(language: .en)

    XCTAssertEqual(
      try String(contentsOf: claudeMd(), encoding: .utf8), OrbeWorkspaceTemplate.claudeMd(.en))
  }

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

  func testNewUserGetsTheFolderOnlyAfterChoosingALanguage() throws {
    let wc = WindowController()
    XCTAssertFalse(FileManager.default.fileExists(atPath: try folder().path), "言語選択の前には作らない")

    let gate = try XCTUnwrap(wc.model.languageSelect)
    gate.selected = try XCTUnwrap(Language.allCases.firstIndex(of: .en))
    gate.activate()

    XCTAssertEqual(
      try String(contentsOf: claudeMd(), encoding: .utf8), OrbeWorkspaceTemplate.claudeMd(.en),
      "選んだ言語の雛形")
  }
}

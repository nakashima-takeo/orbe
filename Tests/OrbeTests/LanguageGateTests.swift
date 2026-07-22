import AppKit
import XCTest

@testable import Orbe

/// 初回言語ゲートの振る舞いを、実 NSWindow + libghostty ランタイムで結合検証する
/// （WindowControllerFocusRestoreTests と同型）。ゲートは init の showFirstRunFlow で走るため、
/// app-state を組んでから WindowController を構築し、`model.languageSelect` の有無で観測する。
final class LanguageGateTests: XCTestCase {
  private var tempStore: URL!

  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-langgate-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
  }

  override func tearDown() {
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  /// preferredLanguage 未選択（app-state 不在）なら、初回起動で言語選択画面を出す。
  func testNewUserShowsLanguageSelect() {
    let wc = WindowController()  // app-state 未保存＝preferredLanguage nil
    XCTAssertNotNil(wc.model.languageSelect, "未選択なら言語画面を出す")
  }

  /// preferredLanguage 確定済み（returning user）なら、言語選択画面をスキップする。
  func testReturningUserSkipsLanguageSelect() {
    AppStatePersistence.save(AppStateFile(preferredLanguage: "en"))
    let wc = WindowController()
    XCTAssertNil(wc.model.languageSelect, "確定済みなら言語画面を出さない")
  }

  /// 言語を確定（activate）すると、選択言語が永続化され現在言語ストアへ反映され、overlay が下がる。
  func testConfirmPersistsAndAppliesLanguage() throws {
    let wc = WindowController()
    let gate = try XCTUnwrap(wc.model.languageSelect)
    gate.selected = try XCTUnwrap(Language.allCases.firstIndex(of: .en))
    gate.activate()

    XCTAssertEqual(
      AppStatePersistence.load()?.preferredLanguage, "en", "確定言語が永続化される")
    XCTAssertEqual(wc.localization.language, .en, "現在言語ストアへ反映される")
    XCTAssertNil(wc.model.languageSelect, "確定後は言語画面を下げる")
  }
}

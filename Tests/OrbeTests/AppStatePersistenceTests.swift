import XCTest

@testable import Orbe

/// `app-state.json` の永続 round-trip を、`preferredLanguage`（初回言語ゲート・起動言語の土台）を
/// 軸に固定する。全 field Optional の家風（欠落を壊さず読む・部分更新で他 field を保つ）を突く。
final class AppStatePersistenceTests: XCTestCase {
  private var tempURL: URL!

  override func setUp() {
    super.setUp()
    tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-appstate-test-\(UUID().uuidString).json")
    AppStatePersistence.fileURLOverride = tempURL
  }

  override func tearDown() {
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempURL)
    super.tearDown()
  }

  func testPreferredLanguageRoundTrips() {
    AppStatePersistence.save(AppStateFile(preferredLanguage: "en"))
    XCTAssertEqual(AppStatePersistence.load()?.preferredLanguage, "en")
  }

  /// nil（＝未選択）は欠落として書かれ、読み戻しても nil のまま（初回ゲートが nil を「言語画面を出す」に使う）。
  func testNilPreferredLanguageRoundTripsAsNil() {
    AppStatePersistence.save(AppStateFile(preferredLanguage: nil))
    let loaded = AppStatePersistence.load()
    XCTAssertNotNil(loaded, "ファイル自体は書かれる")
    XCTAssertNil(loaded?.preferredLanguage, "nil は欠落として復元される")
  }

  /// 部分更新は他 field を保ったまま preferredLanguage だけ変える（散在する書込点が共有する契約）。
  func testUpdateChangesOnlyPreferredLanguage() {
    AppStatePersistence.save(
      AppStateFile(completionInstalled: true, cachedShellPath: "/bin/zsh", preferredLanguage: nil))
    AppStatePersistence.update { $0.preferredLanguage = "ja" }
    let loaded = AppStatePersistence.load()
    XCTAssertEqual(loaded?.preferredLanguage, "ja")
    XCTAssertEqual(loaded?.completionInstalled, true, "他 field は保持")
    XCTAssertEqual(loaded?.cachedShellPath, "/bin/zsh", "他 field は保持")
  }

  /// preferredLanguage を持たない旧 JSON もデコード成功（throw せず）し nil を返す＝後方互換。
  func testDecodesLegacyJsonWithoutPreferredLanguage() throws {
    let legacy = #"{"completionInstalled":true}"#
    try legacy.data(using: .utf8)!.write(to: tempURL)
    let loaded = AppStatePersistence.load()
    XCTAssertEqual(loaded?.completionInstalled, true)
    XCTAssertNil(loaded?.preferredLanguage, "欠落キーは nil（デコード失敗にしない）")
  }

  func testMissingFileLoadsNil() {
    // setUp で override 済みだが未 save＝ファイル不在。
    XCTAssertNil(AppStatePersistence.load(), "ファイル不在は nil（呼び出し側が既定 fallback）")
  }
}

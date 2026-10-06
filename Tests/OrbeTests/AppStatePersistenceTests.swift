import XCTest

@testable import Orbe

/// `app-state.json` の読み書き。壊れると、1 箇所の書き込みが他の内部簿記（言語・プラグイン登録・
/// PATH キャッシュ）を消す、または旧ファイルを読めずに初回扱いへ戻る。
final class AppStatePersistenceTests: OrbeTestCase {

  /// 部分更新は 1 field だけを変え、他の field を保つ（散在する書込点が共有する契約）。
  func testUpdateChangesOnlyTheMutatedField() {
    AppStatePersistence.save(
      AppStateFile(
        agentPluginsInstalled: true, registeredAgentPluginName: "orbe-agent",
        completionInstalled: true, cachedShellPath: "/bin/zsh", preferredLanguage: nil))
    AppStatePersistence.update { $0.preferredLanguage = "ja" }
    let loaded = AppStatePersistence.load()
    XCTAssertEqual(loaded?.preferredLanguage, "ja")
    XCTAssertEqual(loaded?.agentPluginsInstalled, true, "他 field は保持")
    XCTAssertEqual(loaded?.registeredAgentPluginName, "orbe-agent", "他 field は保持")
    XCTAssertEqual(loaded?.completionInstalled, true, "他 field は保持")
    XCTAssertEqual(loaded?.cachedShellPath, "/bin/zsh", "他 field は保持")
  }

  /// preferredLanguage を持たない旧 JSON もデコード成功（throw せず）し nil を返す＝後方互換。
  func testDecodesLegacyJsonWithoutPreferredLanguage() throws {
    let legacy = #"{"completionInstalled":true}"#
    try legacy.data(using: .utf8)!.write(to: appStateFile())
    let loaded = AppStatePersistence.load()
    XCTAssertEqual(loaded?.completionInstalled, true)
    XCTAssertNil(loaded?.preferredLanguage, "欠落キーは nil（デコード失敗にしない）")
  }

  func testMissingFileLoadsNil() {
    // ハーネスが配る隔離先へはまだ何も save していない＝ファイル不在。
    XCTAssertNil(AppStatePersistence.load(), "ファイル不在は nil（呼び出し側が既定 fallback）")
  }
}

import XCTest

@testable import Orbe

/// settings.json（新形式 v1）と app-state.json の読み書き検証。旧形式移行は `SettingsMigrationTests`。
final class SettingsPersistenceTests: XCTestCase {
  private var settingsURL: URL!
  private var appStateURL: URL!

  override func setUp() {
    super.setUp()
    let dir = FileManager.default.temporaryDirectory
    settingsURL = dir.appendingPathComponent("SettingsPersistenceTests-\(UUID().uuidString).json")
    appStateURL = dir.appendingPathComponent("AppStateTests-\(UUID().uuidString).json")
    SettingsPersistence.fileURLOverride = settingsURL
    AppStatePersistence.fileURLOverride = appStateURL
  }

  override func tearDown() {
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: settingsURL)
    try? FileManager.default.removeItem(at: appStateURL)
    super.tearDown()
  }

  /// 新形式レイヤの round-trip（全型が保たれる）。
  func testLayerRoundTrip() {
    var layer = SettingsLayer()
    layer[SettingKeys.fontSize] = 16
    layer[SettingKeys.theme] = .dark
    layer[SettingKeys.fontFamily] = "Menlo"
    layer[SettingKeys.backgroundOpacity] = 80
    layer[SettingKeys.backgroundBlur] = true
    layer[SettingKeys.cursorStyleBlink] = false
    layer[SettingKeys.defaultAgent] = "codex"
    layer[SettingKeys.devFeaturesEnabled] = true
    layer[SettingKeys.agentStateIcons] = ["working": "gearshape"]
    SettingsPersistence.saveGlobal(layer)
    XCTAssertEqual(SettingsPersistence.loadGlobal(), layer)
  }

  /// ディスク表現は canonical key（kebab）＋version マーカー。theme は小文字 rawValue。
  func testDiskRepresentationUsesCanonicalKeys() throws {
    var layer = SettingsLayer()
    layer[SettingKeys.fontSize] = 16
    layer[SettingKeys.theme] = .dark
    SettingsPersistence.saveGlobal(layer)
    let raw = try String(contentsOf: settingsURL, encoding: .utf8)
    XCTAssertTrue(raw.contains("\"version\" : 1"))
    XCTAssertTrue(raw.contains("\"font-size\" : 16"))
    XCTAssertTrue(raw.contains("\"theme\" : \"dark\""), "theme は小文字 rawValue")
  }

  func testMissingFileYieldsEmptyLayer() {
    XCTAssertTrue(SettingsPersistence.loadGlobal().isEmpty)
  }

  /// 未知 key（将来の項目・撤去済み項目）は無視して読む（前方/後方互換）。
  func testUnknownKeysIgnored() throws {
    try Data(#"{"version":1,"values":{"font-size":14,"no-such-key":"x"}}"#.utf8)
      .write(to: settingsURL)
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.fontSize], 14, "既知 key は読める")
  }

  // MARK: - app-state.json

  func testAppStateRoundTrip() {
    AppStatePersistence.save(
      AppStateFile(
        agentPluginsInstalled: true, completionInstalled: true, cachedShellPath: "/usr/bin"))
    let loaded = AppStatePersistence.load()
    XCTAssertEqual(loaded?.agentPluginsInstalled, true)
    XCTAssertEqual(loaded?.completionInstalled, true)
    XCTAssertEqual(loaded?.cachedShellPath, "/usr/bin")
  }

  /// update は既存を読んで 1 field 変え他を温存する。
  func testAppStateUpdatePreservesOtherFields() {
    AppStatePersistence.save(AppStateFile(agentPluginsInstalled: true))
    AppStatePersistence.update { $0.completionInstalled = true }
    let loaded = AppStatePersistence.load()
    XCTAssertEqual(loaded?.agentPluginsInstalled, true, "他フィールドは温存")
    XCTAssertEqual(loaded?.completionInstalled, true)
  }

  func testAppStateMissingFileReturnsNil() {
    XCTAssertNil(AppStatePersistence.load())
  }
}

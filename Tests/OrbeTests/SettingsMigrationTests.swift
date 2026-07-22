import XCTest

@testable import Orbe

/// 旧形式（camelCase・アプリ状態同居の settings.json / camelCase の workspaces.json settingsOverride）から
/// 新形式への**無損失自動移行**を固定する。移行は all-or-nothing（旧ファイル全体の decode 成功時のみ変換）で、
/// 既存ユーザーの設定・WS 上書きを 1 つも失わないことを実 JSON fixture で担保する。
final class SettingsMigrationTests: XCTestCase {
  private var settingsURL: URL!
  private var appStateURL: URL!
  private var workspacesURL: URL!

  override func setUp() {
    super.setUp()
    let dir = FileManager.default.temporaryDirectory
    settingsURL = dir.appendingPathComponent("mig-settings-\(UUID().uuidString).json")
    appStateURL = dir.appendingPathComponent("mig-appstate-\(UUID().uuidString).json")
    workspacesURL = dir.appendingPathComponent("mig-ws-\(UUID().uuidString).json")
    SettingsPersistence.fileURLOverride = settingsURL
    AppStatePersistence.fileURLOverride = appStateURL
    WorkspacePersistence.fileURLOverride = workspacesURL
  }

  override func tearDown() {
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    WorkspacePersistence.fileURLOverride = nil
    for url in [settingsURL, appStateURL, workspacesURL] {
      if let url { try? FileManager.default.removeItem(at: url) }
    }
    super.tearDown()
  }

  // MARK: - settings.json 旧形式 → 新形式（設定 9 項目＋アプリ状態 3 項目）

  /// 全 9 設定＋アプリ状態 3 項目入りの旧 settings.json を無損失で移行する。
  func testLegacySettingsMigrateWithoutLoss() throws {
    let legacy = """
      {"defaultAgent":"codex","agentPluginsInstalled":true,"completionInstalled":true,\
      "cachedShellPath":"/usr/local/bin:/usr/bin","fontSize":16,"theme":"dark",\
      "fontFamily":"Hack","backgroundOpacity":80,"backgroundBlur":true,\
      "cursorStyleBlink":false,"agentStateIcons":{"working":"gearshape"},\
      "devFeaturesEnabled":true}
      """
    try Data(legacy.utf8).write(to: settingsURL)

    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.fontSize], 16)
    XCTAssertEqual(layer[SettingKeys.backgroundOpacity], 80)
    XCTAssertEqual(layer[SettingKeys.backgroundBlur], true)
    XCTAssertEqual(layer[SettingKeys.cursorStyleBlink], false)
    XCTAssertEqual(layer[SettingKeys.theme], .dark)
    XCTAssertEqual(layer[SettingKeys.fontFamily], "Hack")
    XCTAssertEqual(layer[SettingKeys.defaultAgent], "codex")
    XCTAssertEqual(layer[SettingKeys.devFeaturesEnabled], true)
    XCTAssertEqual(layer[SettingKeys.agentStateIcons], ["working": "gearshape"])

    // アプリ状態 3 項目は app-state.json へ分離退避される。
    let app = try XCTUnwrap(AppStatePersistence.load())
    XCTAssertEqual(app.agentPluginsInstalled, true)
    XCTAssertEqual(app.completionInstalled, true)
    XCTAssertEqual(app.cachedShellPath, "/usr/local/bin:/usr/bin")

    // settings.json は新形式（version＋values）へ書き換わり、アプリ状態 field は消える。
    let raw = try String(contentsOf: settingsURL, encoding: .utf8)
    XCTAssertTrue(raw.contains("\"version\" : 1"), "新形式 version マーカー")
    XCTAssertTrue(raw.contains("\"font-size\" : 16"), "canonical key（kebab）で書く")
    XCTAssertFalse(raw.contains("agentPluginsInstalled"), "アプリ状態は settings.json から消える")
    XCTAssertFalse(raw.contains("fontSize"), "camelCase は消える")
  }

  /// 移行後にもう一度 loadGlobal しても再移行せず（既に新形式）、値は同一で round-trip する。
  func testMigratedSettingsRoundTripInNewFormat() throws {
    let legacy = #"{"fontSize":13,"theme":"light","agentStateIcons":{"done":"checkmark.seal"}}"#
    try Data(legacy.utf8).write(to: settingsURL)
    let first = SettingsPersistence.loadGlobal()
    let second = SettingsPersistence.loadGlobal()
    XCTAssertEqual(first, second, "再 load は再移行せず同値")
    XCTAssertEqual(second[SettingKeys.fontSize], 13)
    XCTAssertEqual(second[SettingKeys.theme], .light)
    XCTAssertEqual(second[SettingKeys.agentStateIcons], ["done": "checkmark.seal"])
  }

  /// 旧テーマ名（"Dracula" 等）は移行時に .auto へ丸めて読む（寛容 decode で全設定を失わない）。
  func testLegacyThemeNameRoundsToAutoWithoutLosingOtherSettings() throws {
    try Data(#"{"defaultAgent":"claude","fontSize":16,"theme":"Dracula"}"#.utf8)
      .write(to: settingsURL)
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.theme], .auto, "旧テーマ名は Auto へ丸める")
    XCTAssertEqual(layer[SettingKeys.fontSize], 16, "他設定は失わない")
    XCTAssertEqual(layer[SettingKeys.defaultAgent], "claude")
  }

  /// 撤去済みキー（cursorColor 等）を含む旧ファイルも他設定を壊さず移行する。
  func testLegacyFileWithRemovedKeyMigrates() throws {
    try Data(##"{"defaultAgent":"claude","cursorColor":"#89B4FA","fontSize":16}"##.utf8)
      .write(to: settingsURL)
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.defaultAgent], "claude")
    XCTAssertEqual(layer[SettingKeys.fontSize], 16)
  }

  // MARK: - degenerate（空・欠落・壊れ）は既定へ fallback

  func testMissingSettingsFileYieldsEmptyLayer() {
    XCTAssertTrue(SettingsPersistence.loadGlobal().isEmpty, "欠落は空層（既定へ fallback）")
  }

  func testBrokenSettingsFileYieldsEmptyLayer() throws {
    try Data("{".utf8).write(to: settingsURL)
    XCTAssertTrue(SettingsPersistence.loadGlobal().isEmpty, "壊れは空層（既定へ fallback）")
  }

  /// v1 settings.json の既知キー1件が型不一致でも、他の健全な設定を巻き込んで全消去しない。
  /// 悪いキーだけ落として残りを返し、load ではファイルを一切書き換えない（version 基盤の前方互換で
  /// 既存キーの型が変わっても既存ユーザー設定を失わない）。F1 の回帰ガード。
  func testV1FileWithOneTypeMismatchKeepsOtherSettingsAndDoesNotRewrite() throws {
    let raw = #"{"version":1,"values":{"font-size":"oops","theme":"dark","default-agent":"codex"}}"#
    try Data(raw.utf8).write(to: settingsURL)
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertNil(layer[SettingKeys.fontSize], "型不一致の font-size は落ちる")
    XCTAssertEqual(layer[SettingKeys.theme], .dark, "健全な他項目は生存する")
    XCTAssertEqual(layer[SettingKeys.defaultAgent], "codex")
    let after = try String(contentsOf: settingsURL, encoding: .utf8)
    XCTAssertEqual(after, raw, "load では settings.json を書き換えない（原資産を保持）")
  }

  /// version エンベロープを持つが values が構造破損（非オブジェクト）でも、破壊的な旧移行 save に落ちず
  /// 空層で fallback しファイルを上書きしない（version 判別で legacy 空移行を封じる・F1 案C）。
  func testCorruptV1ValuesDoesNotWipeFile() throws {
    let raw = #"{"version":1,"values":123}"#
    try Data(raw.utf8).write(to: settingsURL)
    XCTAssertTrue(SettingsPersistence.loadGlobal().isEmpty, "構造破損 v1 は空層 fallback")
    let after = try String(contentsOf: settingsURL, encoding: .utf8)
    XCTAssertEqual(after, raw, "破損 v1 でも load でファイルを書き換えない")
  }

  // MARK: - workspaces.json settingsOverride 旧 camelCase → 新形式

  /// 旧 camelCase の settingsOverride を持つ workspaces.json も無損失で読み、上書き層へ変換する。
  /// 旧 override が扱える scopable 7 項目すべてを 1 fixture で個別 assert する（1 項目でも
  /// `LegacyWorkspaceSettingsOverride.toLayer()` が落とせば喪失なので全項目を固定する）。
  func testLegacyWorkspaceOverrideMigrates() throws {
    let legacy = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,\
      "tabs":[{"tree":{"leaf":{}},"editor":{"open":false,"tool":"tree"}}],\
      "settingsOverride":{"fontSize":16,"backgroundOpacity":70,"backgroundBlur":true,\
      "theme":"dark","fontFamily":"Hack","cursorStyleBlink":false,\
      "agentStateIcons":{"working":"gearshape"}}}]}
      """
    try Data(legacy.utf8).write(to: workspacesURL)
    let file = try XCTUnwrap(WorkspacePersistence.load(), "旧 override 入りでも load 成功")
    let override = try XCTUnwrap(file.workspaces[0].settingsOverride, "上書き層へ変換される")
    XCTAssertEqual(override[SettingKeys.fontSize], 16)
    XCTAssertEqual(override[SettingKeys.backgroundOpacity], 70)
    XCTAssertEqual(override[SettingKeys.backgroundBlur], true)
    XCTAssertEqual(override[SettingKeys.theme], .dark)
    XCTAssertEqual(override[SettingKeys.fontFamily], "Hack")
    XCTAssertEqual(override[SettingKeys.cursorStyleBlink], false)
    XCTAssertEqual(override[SettingKeys.agentStateIcons], ["working": "gearshape"])
  }

  /// 新形式（canonical key）の settingsOverride はそのまま読める（strict decode で受理）。
  func testNewFormatWorkspaceOverrideLoads() throws {
    let new = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,\
      "tabs":[{"tree":{"leaf":{}},"editor":{"open":false,"tool":"tree"}}],\
      "settingsOverride":{"font-size":18,"default-agent":"codex"}}]}
      """
    try Data(new.utf8).write(to: workspacesURL)
    let file = try XCTUnwrap(WorkspacePersistence.load())
    let override = try XCTUnwrap(file.workspaces[0].settingsOverride)
    XCTAssertEqual(override[SettingKeys.fontSize], 18)
    XCTAssertEqual(override[SettingKeys.defaultAgent], "codex")
  }
}

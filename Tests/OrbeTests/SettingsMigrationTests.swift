import XCTest

@testable import Orbe

/// 旧形式（camelCase・アプリ状態同居の settings.json / camelCase の workspaces.json settingsOverride）から
/// 新形式への**無損失自動移行**を固定する。移行は all-or-nothing（旧ファイル全体の decode 成功時のみ変換）で、
/// 既存ユーザーの設定・WS 上書きを 1 つも失わないことを実 JSON fixture で担保する。
final class SettingsMigrationTests: OrbeTestCase {

  // MARK: - settings.json 旧形式 → 新形式（設定 8 項目＋アプリ状態 3 項目）

  /// 全 8 設定＋アプリ状態 3 項目入りの旧 settings.json を無損失で移行する。
  func testLegacySettingsMigrateWithoutLoss() throws {
    let legacy = """
      {"defaultAgent":"codex","agentPluginsInstalled":true,"completionInstalled":true,\
      "cachedShellPath":"/usr/local/bin:/usr/bin","fontSize":16,"theme":"dark",\
      "fontFamily":"Hack","backgroundOpacity":80,"backgroundBlur":true,\
      "cursorStyleBlink":false,"agentStateIcons":{"working":"gearshape"}}
      """
    try Data(legacy.utf8).write(to: settingsFile())

    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.fontSize], 16)
    XCTAssertEqual(layer[SettingKeys.backgroundOpacity], 80)
    XCTAssertEqual(layer[SettingKeys.backgroundBlur], true)
    XCTAssertEqual(layer[SettingKeys.cursorStyleBlink], false)
    XCTAssertEqual(layer[SettingKeys.theme], .dark)
    XCTAssertEqual(layer[SettingKeys.fontFamily], "Hack")
    XCTAssertEqual(layer[SettingKeys.defaultAgent], "codex")
    XCTAssertEqual(layer[SettingKeys.agentStateIcons], ["working": "gearshape"])

    // アプリ状態 3 項目は app-state.json へ分離退避される。
    let app = try XCTUnwrap(AppStatePersistence.load())
    XCTAssertEqual(app.agentPluginsInstalled, true)
    XCTAssertEqual(app.completionInstalled, true)
    XCTAssertEqual(app.cachedShellPath, "/usr/local/bin:/usr/bin")

    // settings.json は新形式（version＋values）へ書き換わり、アプリ状態 field は消える。
    let raw = try String(contentsOf: settingsFile(), encoding: .utf8)
    XCTAssertTrue(raw.contains("\"version\" : 1"), "新形式 version マーカー")
    XCTAssertTrue(raw.contains("\"font-size\" : 16"), "canonical key（kebab）で書く")
    XCTAssertFalse(raw.contains("agentPluginsInstalled"), "アプリ状態は settings.json から消える")
    XCTAssertFalse(raw.contains("fontSize"), "camelCase は消える")
  }

  /// 移行後にもう一度 loadGlobal しても再移行せず（既に新形式）、値は同一で round-trip する。
  func testMigratedSettingsRoundTripInNewFormat() throws {
    let legacy = #"{"fontSize":13,"theme":"light","agentStateIcons":{"done":"checkmark.seal"}}"#
    try Data(legacy.utf8).write(to: settingsFile())
    let first = SettingsPersistence.loadGlobal()
    let second = SettingsPersistence.loadGlobal()
    XCTAssertEqual(first, second, "再 load は再移行せず同値")
    XCTAssertEqual(second[SettingKeys.fontSize], 13)
    XCTAssertEqual(second[SettingKeys.theme], .light)
    XCTAssertEqual(second[SettingKeys.agentStateIcons], ["done": "checkmark.seal"])
  }

  /// 値域外の `theme` を含む旧ファイルも、他設定を巻き込まず移行する。`theme` は移行 struct で
  /// `ThemeMode` として型付けして読むため、値域外は既定（Auto）として層に載る。
  ///
  /// workspace 上書きの移行は同じ値を生の文字列のまま層へ載せる（解決時に既定へ落ちるので実効値は
  /// 一致する）。両者で差の出る値は書き込み経路の値域検証を通れないので、意味を揃えてはいない。
  func testOutOfRangeThemeMigratesWithoutLosingOtherSettings() throws {
    try Data(#"{"defaultAgent":"claude","fontSize":16,"theme":"Dracula"}"#.utf8)
      .write(to: settingsFile())
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.theme], .auto, "値域外の theme は既定として載る")
    XCTAssertEqual(layer[SettingKeys.fontSize], 16, "他設定は失わない")
    XCTAssertEqual(layer[SettingKeys.defaultAgent], "claude")
  }

  /// 撤去済みキー（cursorColor 等）を含む旧ファイルも他設定を壊さず移行する。
  func testLegacyFileWithRemovedKeyMigrates() throws {
    try Data(##"{"defaultAgent":"claude","cursorColor":"#89B4FA","fontSize":16}"##.utf8)
      .write(to: settingsFile())
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.defaultAgent], "claude")
    XCTAssertEqual(layer[SettingKeys.fontSize], 16)
  }

  /// 移行は app-state.json の既存項目を潰さない。旧 settings.json は `preferredLanguage` も
  /// `registeredAgentPluginName` も持たないので、全体上書きするとこの 2 つが消える
  /// ——言語が未選択に戻って初回言語選択画面が再び出る／プラグインが毎起動登録し直される。
  func testMigrationMergesIntoExistingAppState() throws {
    AppStatePersistence.save(
      AppStateFile(registeredAgentPluginName: "orbe-notify-v2", preferredLanguage: "ja"))
    let legacy = """
      {"agentPluginsInstalled":true,"completionInstalled":true,\
      "cachedShellPath":"/usr/local/bin:/usr/bin","fontSize":16}
      """
    try Data(legacy.utf8).write(to: settingsFile())

    _ = SettingsPersistence.loadGlobal()

    let app = try XCTUnwrap(AppStatePersistence.load())
    XCTAssertEqual(app.preferredLanguage, "ja", "旧形式が持たない項目は移行で消えない")
    XCTAssertEqual(app.registeredAgentPluginName, "orbe-notify-v2", "旧形式が持たない項目は移行で消えない")
    XCTAssertEqual(app.agentPluginsInstalled, true, "旧形式の項目は入る")
    XCTAssertEqual(app.completionInstalled, true, "旧形式の項目は入る")
    XCTAssertEqual(app.cachedShellPath, "/usr/local/bin:/usr/bin", "旧形式の項目は入る")
  }

  /// 移行が中断（app-state を書いた後・settings.json 置換の前でクラッシュ）した後の再移行は、
  /// その間に書かれた app-state を巻き戻さない。マージなら再移行は同じ値を上書きするだけで無害になる。
  ///
  /// 巻き戻し対象は「旧形式が語彙として持たない項目」（preferredLanguage）だけではない。旧形式が
  /// 語彙としては持つが**この 1 ファイルには書かれていない**項目（ここでは cachedShellPath）も、
  /// nil をそのまま代入すれば消える——だから移行後に立った値を混ぜて、欠落を nil 上書きに変える
  /// 実装をここで落とす（消えると起動復元の resume が login shell の起動を待つことになる）。
  func testReMigrationDoesNotUndoInterveningAppStateWrites() throws {
    let legacy = #"{"agentPluginsInstalled":true,"fontSize":16}"#
    try Data(legacy.utf8).write(to: settingsFile())
    _ = SettingsPersistence.loadGlobal()  // 1 回目の移行

    // 移行後にユーザーが言語を選び、PATH 検出も走る（後者は旧ファイルに無い項目）。
    AppStatePersistence.update {
      $0.preferredLanguage = "ja"
      $0.cachedShellPath = "/usr/local/bin:/usr/bin"
    }
    let before = try Data(contentsOf: appStateFile())

    try Data(legacy.utf8).write(to: settingsFile())  // 中断クラッシュ相当（旧形式のまま残っている）
    _ = SettingsPersistence.loadGlobal()  // 再移行

    XCTAssertEqual(
      try Data(contentsOf: appStateFile()), before, "再移行は app-state を 1 バイトも変えない")
  }

  // MARK: - degenerate（空・欠落・壊れ）は既定へ fallback

  func testMissingSettingsFileYieldsEmptyLayer() {
    XCTAssertTrue(SettingsPersistence.loadGlobal().isEmpty, "欠落は空層（既定へ fallback）")
  }

  func testBrokenSettingsFileYieldsEmptyLayer() throws {
    try Data("{".utf8).write(to: settingsFile())
    XCTAssertTrue(SettingsPersistence.loadGlobal().isEmpty, "壊れは空層（既定へ fallback）")
  }

  /// v1 settings.json の既知キー1件が型不一致でも、他の健全な設定を巻き込んで全消去しない。
  /// 悪いキーだけ落として残りを返し、load ではファイルを一切書き換えない（version 基盤の前方互換で
  /// 既存キーの型が変わっても既存ユーザー設定を失わない）。F1 の回帰ガード。
  func testV1FileWithOneTypeMismatchKeepsOtherSettingsAndDoesNotRewrite() throws {
    let raw = #"{"version":1,"values":{"font-size":"oops","theme":"dark","default-agent":"codex"}}"#
    try Data(raw.utf8).write(to: settingsFile())
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertNil(layer[SettingKeys.fontSize], "型不一致の font-size は落ちる")
    XCTAssertEqual(layer[SettingKeys.theme], .dark, "健全な他項目は生存する")
    XCTAssertEqual(layer[SettingKeys.defaultAgent], "codex")
    let after = try String(contentsOf: settingsFile(), encoding: .utf8)
    XCTAssertEqual(after, raw, "load では settings.json を書き換えない（原資産を保持）")
  }

  /// version エンベロープを持つが values が構造破損（非オブジェクト）でも、破壊的な旧移行 save に落ちず
  /// 空層で fallback しファイルを上書きしない（version 判別で legacy 空移行を封じる・F1 案C）。
  func testCorruptV1ValuesDoesNotWipeFile() throws {
    let raw = #"{"version":1,"values":123}"#
    try Data(raw.utf8).write(to: settingsFile())
    XCTAssertTrue(SettingsPersistence.loadGlobal().isEmpty, "構造破損 v1 は空層 fallback")
    let after = try String(contentsOf: settingsFile(), encoding: .utf8)
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
      "tabs":[{"tree":{"leaf":{}}}],\
      "settingsOverride":{"fontSize":16,"backgroundOpacity":70,"backgroundBlur":true,\
      "theme":"dark","fontFamily":"Hack","cursorStyleBlink":false,\
      "agentStateIcons":{"working":"gearshape"}}}]}
      """
    try Data(legacy.utf8).write(to: workspacesFile())
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

  /// 新形式（canonical key）の settingsOverride はそのまま読める。
  func testNewFormatWorkspaceOverrideLoads() throws {
    let new = """
      {"version":3,"activeWorkspace":0,"workspaces":[\
      {"name":"a","rootPath":"/","activeTab":0,\
      "tabs":[{"tree":{"leaf":{}}}],\
      "settingsOverride":{"font-size":18,"default-agent":"codex"}}]}
      """
    try Data(new.utf8).write(to: workspacesFile())
    let file = try XCTUnwrap(WorkspacePersistence.load())
    let override = try XCTUnwrap(file.workspaces[0].settingsOverride)
    XCTAssertEqual(override[SettingKeys.fontSize], 18)
    XCTAssertEqual(override[SettingKeys.defaultAgent], "codex")
  }
}

import XCTest

@testable import Orbe

/// settings.json（新形式 v1）と app-state.json の読み書き検証。旧形式移行は `SettingsMigrationTests`。
final class SettingsPersistenceTests: OrbeTestCase {

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
    layer[SettingKeys.agentStateIcons] = ["working": "gearshape"]
    layer[SettingKeys.notificationSound] = .custom
    layer[SettingKeys.notificationSoundCustomDone] = CustomSoundSource(
      file: "a1b2.wav", name: "chime.mp3", duration: 1.834)
    layer[SettingKeys.notificationSoundCustomWaitingSameAsDone] = false
    SettingsPersistence.saveGlobal(layer)
    XCTAssertEqual(SettingsPersistence.loadGlobal(), layer)
  }

  /// カスタム音源はディスク上では 3 フィールドの map（file/name/duration）で、往復しても値が動かない。
  func testCustomSoundSourceDiskRepresentation() throws {
    var layer = SettingsLayer()
    layer[SettingKeys.notificationSoundCustomDone] = CustomSoundSource(
      file: "a1b2.wav", name: "chime.mp3", duration: 1.834)
    SettingsPersistence.saveGlobal(layer)
    let raw = try String(contentsOf: settingsFile(), encoding: .utf8)
    XCTAssertTrue(raw.contains("\"notification-sound-custom-done\""))
    XCTAssertTrue(raw.contains("\"file\" : \"a1b2.wav\""))
    XCTAssertTrue(raw.contains("\"duration\" : \"1.834\""), "秒はミリ秒まで（往復しても丸め直されない）")
  }

  /// 不正な map（file 欠損・duration が数値でない・duration が 0 以下）は**未設定**として読む
  /// ——parse は 1 箇所（`CustomSoundSource`）に閉じているので、どの経路から来ても同じ規則になる。
  func testMalformedCustomSoundSourceReadsAsUnset() throws {
    for bad in [
      #"{"name":"x","duration":"1.0"}"#,  // file 欠損
      #"{"file":"a.wav","duration":"nope"}"#,  // duration が数値でない
      #"{"file":"a.wav","duration":"0"}"#,  // 長さゼロ
      #"{"file":"../evil.wav","duration":"1.0"}"#,  // ディレクトリを跨ぐ名前
    ] {
      try Data(#"{"version":1,"values":{"notification-sound-custom-done":\#(bad)}}"#.utf8)
        .write(to: settingsFile())
      XCTAssertNil(
        SettingsPersistence.loadGlobal()[SettingKeys.notificationSoundCustomDone], bad)
    }
  }

  /// name だけが欠けている map は未設定にしない（鳴らせる実体はあるので、表示名を file で代替する）。
  func testCustomSoundSourceWithoutNameFallsBackToTheFileName() throws {
    try Data(
      #"{"version":1,"values":{"notification-sound-custom-done":{"file":"a.wav","duration":"2.5"}}}"#
        .utf8
    ).write(to: settingsFile())
    let source = SettingsPersistence.loadGlobal()[SettingKeys.notificationSoundCustomDone]
    XCTAssertEqual(source, CustomSoundSource(file: "a.wav", name: "a.wav", duration: 2.5))
  }

  /// 未知の案名（旧バージョンが書いた値・手書きの誤り）は未設定として読み、実効は既定へ落ちる。
  func testUnknownNotificationSoundReadsAsUnset() throws {
    try Data(#"{"version":1,"values":{"notification-sound":"no-such-sound"}}"#.utf8)
      .write(to: settingsFile())
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertNil(layer[SettingKeys.notificationSound])
    XCTAssertEqual(EffectiveSettings(layer)[SettingKeys.notificationSound], .default)
  }

  /// ディスク表現は canonical key（kebab）＋version マーカー。theme は小文字 rawValue。
  func testDiskRepresentationUsesCanonicalKeys() throws {
    var layer = SettingsLayer()
    layer[SettingKeys.fontSize] = 16
    layer[SettingKeys.theme] = .dark
    SettingsPersistence.saveGlobal(layer)
    let raw = try String(contentsOf: settingsFile(), encoding: .utf8)
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
      .write(to: settingsFile())
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.fontSize], 14, "既知 key は読める")
  }

  /// 人が手で書いた値域外の int は、読んだ時点で domain の端へ丸まる。
  /// 素通しすると値域は「設定パレット経由でだけ守られる約束」に痩せ、下流が値域を前提にできない。
  func testOutOfRangeIntClampedOnLoad() throws {
    try Data(
      #"{"version":1,"values":{"font-size":500,"background-opacity":0,"notification-sound-volume":0}}"#
        .utf8
    ).write(to: settingsFile())
    let layer = SettingsPersistence.loadGlobal()
    XCTAssertEqual(layer[SettingKeys.fontSize], 72, "上限超えは上限へ")
    XCTAssertEqual(layer[SettingKeys.backgroundOpacity], 20, "下限未満は下限へ")
    XCTAssertEqual(
      layer[SettingKeys.notificationSoundVolume], 5,
      "手書きの音量 0 も下限へ——ここが丸めるので、鳴らす判断は音量を見なくてよい")
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

import OrbeSound
import XCTest

@testable import Orbe

/// 再生層への配達経路（ファイル分割の拡張）。鳴らす**判断**そのものは `AgentSoundDecisionTests` が
/// 純関数で総当たりするので、ここで測るのは `report_agent` 側の「発火点が正しいか（waiting / done への
/// 実変化だけか）」「見ているタブ・休眠 workspace で抑制されるか」「どの workspace の設定を読むか」と、
/// 設定パレット側の「試聴のコールバックが再生層へ繋がっているか」。
/// 再生層は隔離ハーネスがフェイクへ差してある。
extension WindowControllerReportAgentTests {
  private func recorder(_ wc: WindowController) throws -> SoundPlayerFake {
    try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake, "隔離ハーネスが再生層をフェイクへ差していない")
  }

  /// waiting / done への実変化だけが鳴る（②ピルと同じ条件）。
  func testSoundFiresOnlyOnWaitingOrDoneChange() throws {
    let (wc, pane) = try makeControllerAndPane()
    XCTAssertFalse(wc.window.isKeyWindow, "前提: 背面（非 key）なので見ているタブの抑制は効かない")
    let sound = try recorder(wc)

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "working", sessionId: nil, message: nil)
    XCTAssertTrue(sound.played.isEmpty, "working への変化では鳴らさない")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertEqual(
      sound.played,
      [
        SoundPlayerFake.Played(family: NotificationSound.default, event: .waiting, volume: 70)
      ], "既定の案・既定の音量で入力待ちが鳴る")

    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertEqual(sound.played.count, 1, "同値報告（変化なし）では鳴らさない")

    wc.controlReportAgent(pane: pane, agent: "claude", state: "done", sessionId: nil, message: nil)
    XCTAssertEqual(sound.played.last?.event, .done)

    wc.controlReportAgent(pane: pane, agent: "claude", state: "clear", sessionId: nil, message: nil)
    XCTAssertEqual(sound.played.count, 2, "clear では鳴らさない")
  }

  /// 見ているタブ（前面ウィンドウのアクティブ表示タブ）のペインでは鳴らさない。別タブなら鳴る
  /// ——端末にその結果もプロンプトも出ている面で、注意を二重に奪わないため（②の抑制と同じ判定）。
  func testSoundSuppressedOnVisibleTabOnly() throws {
    let (wc, panes) = try makeControllerAndTwoTabs()
    makeKey(wc)
    let sound = try recorder(wc)

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertTrue(sound.played.isEmpty, "見ているタブ（タブ0）では鳴らさない")

    wc.controlReportAgent(
      pane: panes[1], agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertEqual(sound.played.count, 1, "見ていないタブ（タブ1）では鳴る")
  }

  /// 通知音がオフなら鳴らない（設定はライブに効く＝鳴らす直前に実効設定を読む）。
  func testDisabledSettingSilencesTheReport() throws {
    let (wc, pane) = try makeControllerAndPane()
    let sound = try recorder(wc)
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.notificationSoundEnabled, false))

    wc.controlReportAgent(pane: pane, agent: "claude", state: "done", sessionId: nil, message: nil)
    XCTAssertTrue(sound.played.isEmpty)

    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.notificationSoundEnabled, true))
    wc.controlReportAgent(
      pane: pane, agent: "claude", state: "waiting", sessionId: nil, message: nil)
    XCTAssertEqual(sound.played.count, 1, "オンへ戻せば次の報告から鳴る")
  }

  /// 読むのは**発信元ペインが属する workspace** の実効設定（「この workspace のエージェントはこの音」
  /// という上書きが意味を持つのはこの読み方だけ）。
  ///
  /// workspace を 2 つ立てて**アクティブでない方**から報告させる——1 つしか無いと発信元＝アクティブに
  /// なり、アクティブの実効設定を読む誤実装（`activeEffectiveSettings()`）でも同じく緑になる。
  func testSoundReadsOriginWorkspaceOverride() throws {
    let (wc, panes) = try makeControllerAndTwoActivatedWorkspaces()
    let sound = try recorder(wc)
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.notificationSound, .glass))
    var originOverride = SettingsLayer()
    originOverride[SettingKeys.notificationSound] = NotificationSound.steel
    originOverride[SettingKeys.notificationSoundVolume] = 30
    wc.workspaces[0].settingsOverride = originOverride
    var activeOverride = SettingsLayer()
    activeOverride[SettingKeys.notificationSound] = NotificationSound.wood
    activeOverride[SettingKeys.notificationSoundVolume] = 90
    wc.workspaces[1].settingsOverride = activeOverride
    XCTAssertTrue(wc.current === wc.workspaces[1], "前提: アクティブは発信元でない方")

    wc.controlReportAgent(
      pane: panes[0], agent: "claude", state: "done", sessionId: nil, message: nil)
    XCTAssertEqual(
      sound.played, [SoundPlayerFake.Played(family: .steel, event: .done, volume: 30)],
      "アクティブ側でなく発信元 workspace の上書きで鳴る")
  }

  /// 設定パレットの試聴コールバックが再生層へ繋がっている（案は鳴らし、「なし」行は止める）。
  /// モデル側の「どちらを配るか」は `SettingsPaletteSoundTests` が測るので、ここは配線だけ。
  func testPreviewCallbackReachesThePlayer() throws {
    let (wc, _) = try makeControllerAndPane()
    let sound = try recorder(wc)
    wc.showSettingsPalette()
    let palette = try XCTUnwrap(wc.model.settingsPalette)

    palette.onPreviewSound?(.wood, .waiting, 70)
    XCTAssertEqual(sound.played.last, .init(family: .wood, event: .waiting, volume: 70))
    XCTAssertEqual(sound.stopCount, 0)

    palette.onPreviewSound?(nil, .waiting, 70)
    XCTAssertEqual(sound.stopCount, 1, "「なし」行は鳴らさず止めるだけ")
    XCTAssertEqual(sound.played.count, 1)
  }

  /// 休眠（未 activate）workspace のペインからの報告では鳴らさない——②が「幽霊ピルになる」として
  /// 立てないのと同じ集合。一覧にもピルにも出ない音だけが鳴ると、ユーザは出所を辿れない。
  func testDormantWorkspacePaneIsSilent() throws {
    let (wc, dormant) = try makeControllerAndDormantPane()
    let sound = try recorder(wc)

    wc.controlReportAgent(
      pane: dormant, agent: "claude", state: "done", sessionId: nil, message: nil)
    XCTAssertTrue(sound.played.isEmpty)
  }
}

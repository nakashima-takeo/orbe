import OrbeSound
import XCTest

@testable import Orbe

/// 再生層への配達経路（ファイル分割の拡張）。鳴らす**判断**そのものは `AgentSoundDecisionTests` が
/// 純関数で持つ。鳴らすかどうかの成立条件（waiting / done への実変化・見ているタブ・休眠 workspace）は
/// ②ピルと同じ 1 つの通知（`agentNotification`）が解くので、本体ファイルと +Reprojection のピル側が測る。
/// ここで測るのは「どの workspace の設定を読むか」「取り込み音源が化けずに届くか」と、設定パレット側の
/// 「試聴のコールバックが再生層へ繋がっているか」。再生層は隔離ハーネスがフェイクへ差してある。
extension WindowControllerReportAgentTests {
  private func recorder(_ wc: WindowController) throws -> SoundPlayerFake {
    try XCTUnwrap(wc.soundPlayer as? SoundPlayerFake, "隔離ハーネスが再生層をフェイクへ差していない")
  }

  /// 読むのは**発信元タブが属する workspace** の実効設定（「この workspace のエージェントはこの音」
  /// という上書きが意味を持つのはこの読み方だけ）。
  ///
  /// workspace を 2 つ立てて**アクティブでない方**から報告させる——1 つしか無いと発信元＝アクティブに
  /// なり、アクティブの実効設定を読む誤実装（`activeEffectiveSettings()`）でも同じく緑になる。
  func testSoundReadsOriginWorkspaceOverride() throws {
    let (wc, tabs) = try makeControllerAndTwoActivatedWorkspaces()
    let sound = try recorder(wc)
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.notificationSound, .preset(.glass)))
    var originOverride = SettingsLayer()
    originOverride[SettingKeys.notificationSound] = .preset(.steel)
    originOverride[SettingKeys.notificationSoundVolume] = 30
    wc.workspaces[0].settingsOverride = originOverride
    var activeOverride = SettingsLayer()
    activeOverride[SettingKeys.notificationSound] = .preset(.wood)
    activeOverride[SettingKeys.notificationSoundVolume] = 90
    wc.workspaces[1].settingsOverride = activeOverride
    XCTAssertTrue(wc.current === wc.workspaces[1], "前提: アクティブは発信元でない方")

    wc.controlReportAgent(tab: tabs[0], report: AgentHookReport(agent: "claude", state: "done"))
    XCTAssertEqual(
      sound.played, [SoundPlayerFake.Played.synth(.steel, event: .done, volume: 30)],
      "アクティブ側でなく発信元 workspace の上書きで鳴る")
  }

  /// 設定パレットの試聴コールバックが再生層へ繋がっている（案は鳴らし、「なし」行は止める）。
  /// モデル側の「どちらを配るか」は `SettingsPaletteSoundTests` が測るので、ここは配線だけ。
  func testPreviewCallbackReachesThePlayer() throws {
    let (wc, _) = try makeControllerAndTab()
    let sound = try recorder(wc)
    wc.showSettingsPalette()
    let palette = try XCTUnwrap(wc.model.settingsPalette)

    palette.onPreviewSound?(.synth(.wood), .waiting, 70)
    XCTAssertEqual(sound.played.last, .synth(.wood, event: .waiting, volume: 70))
    XCTAssertEqual(sound.stopCount, 0)

    palette.onPreviewSound?(nil, .waiting, 70)
    XCTAssertEqual(sound.stopCount, 1, "「なし」行は鳴らさず止めるだけ")
    XCTAssertEqual(sound.played.count, 1)
  }

  /// カスタム選択なら、取り込み済み音源が `.imported` のまま再生層へ届く（発信元 workspace の
  /// 上書きが効く経路も同じ）——解決は `AgentSoundDecision` が持ち、配達の途中で案へ化けない。
  func testCustomSourceReachesThePlayer() throws {
    let (wc, tabs) = try makeControllerAndTwoActivatedWorkspaces()
    let sound = try recorder(wc)
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.notificationSound, .custom))
    var originOverride = SettingsLayer()
    originOverride[SettingKeys.notificationSoundCustomDone] = CustomSoundSource(
      file: "origin.wav", name: "origin.mp3", duration: 1.5)
    wc.workspaces[0].settingsOverride = originOverride

    wc.controlReportAgent(tab: tabs[0], report: AgentHookReport(agent: "claude", state: "done"))
    XCTAssertEqual(
      sound.played,
      [SoundPlayerFake.Played(source: .imported(file: "origin.wav"), event: .done, volume: 90)])

    // アクティブ側（上書き無し＝カスタム未設定）は紋章の同 event 音へ落ちる。
    wc.controlReportAgent(tab: tabs[1], report: AgentHookReport(agent: "claude", state: "waiting"))
    XCTAssertEqual(
      sound.played.last, .synth(NotificationSound.default, event: .waiting, volume: 90))
  }

  // MARK: - 参照集合 GC（実経路）

  private func placeSound(_ name: String) throws {
    try Data("wav".utf8).write(to: try XCTUnwrap(CustomSoundStore.url(for: name)))
  }

  private func soundFileNames() throws -> Set<String> {
    let dir = try XCTUnwrap(CustomSoundStore.directoryURL())
    return Set(
      try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent))
  }

  /// global へ取り込んでも、**workspace 上書き層が参照する音源は消えない**。
  ///
  /// 参照集合が全層（global ＋ 全 workspace 上書き）を走ることと、順序が「新ファイルを書く →
  /// 設定値を差し替える → GC」であることを、production の 1 経路（`applySetting`）で同時に押さえる
  /// ——集合が層を取りこぼせば `ws.wav` が、順序が逆なら `new.wav` が消えて落ちる。
  func testImportKeepsSoundsReferencedByOtherLayers() throws {
    let (wc, _) = try makeControllerAndTwoActivatedWorkspaces()
    for name in ["ws.wav", "old.wav", "new.wav"] { try placeSound(name) }

    var wsOverride = SettingsLayer()
    wsOverride[SettingKeys.notificationSoundCustomDone] = CustomSoundSource(
      file: "ws.wav", name: "ws.mp3", duration: 1)
    wc.workspaces[0].settingsOverride = wsOverride
    wc.settingsStore.applyGlobal(
      SettingChange(
        SettingKeys.notificationSoundCustomDone,
        CustomSoundSource(file: "old.wav", name: "old.mp3", duration: 1)))

    wc.applySetting(
      SettingChange(
        SettingKeys.notificationSoundCustomDone,
        CustomSoundSource(file: "new.wav", name: "new.mp3", duration: 2)), scope: .global)

    XCTAssertEqual(try soundFileNames(), ["ws.wav", "new.wav"], "参照されなくなった old だけが消える")
  }

  /// workspace を閉じると、その workspace だけが参照していた音源が回収される。
  /// **残った workspace の参照は消えない**——ここが崩れると、無関係な workspace の音が黙って紋章に戻る。
  func testClosingWorkspaceReclaimsOnlyItsOwnSound() throws {
    let (wc, _) = try makeControllerAndTwoActivatedWorkspaces()
    for name in ["gone.wav", "kept.wav"] { try placeSound(name) }

    for (index, file) in [(0, "gone.wav"), (1, "kept.wav")] {
      var override = SettingsLayer()
      override[SettingKeys.notificationSoundCustomDone] = CustomSoundSource(
        file: file, name: file, duration: 1)
      wc.workspaces[index].settingsOverride = override
    }

    wc.closeWorkspace(0, origin: .gesture)

    XCTAssertEqual(try soundFileNames(), ["kept.wav"], "残った workspace の上書きが指す音源は消えない")
  }
}

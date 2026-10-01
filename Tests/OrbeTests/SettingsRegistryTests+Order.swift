import XCTest

@testable import Orbe

extension SettingsRegistryTests {
  // MARK: - 2 つの順序リスト（別物）

  /// `all` は gui.conf の正準出力順。この順が `GuiConfig.regenerate` の出力バイト順を決める。
  func testAllIsCanonicalGuiConfOrder() {
    XCTAssertEqual(
      SettingsRegistry.all.map(\.id),
      [
        .fontSize, .fontFamily, .tabTitleFontFamily, .emojiFont, .theme, .defaultAgent,
        .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .agentStateIcons,
        .worktreeDir, .notificationSound, .notificationSoundVolume,
        .notificationSoundEnabled, .notificationSoundCustomDone, .notificationSoundCustomWaiting,
        .notificationSoundCustomWaitingSameAsDone, .menuBarNotificationDuration,
      ])
  }

  /// `rootOrder` は設定パレット root の表示順。
  func testRootOrderIsDisplayOrder() {
    XCTAssertEqual(
      SettingsRegistry.rootOrder.map(\.id),
      [
        .fontSize, .backgroundOpacity, .backgroundBlur, .cursorStyleBlink, .theme,
        .defaultAgent, .fontFamily, .tabTitleFontFamily, .emojiFont, .agentStateIcons,
        .worktreeDir, .notificationSound, .notificationSoundVolume,
        .notificationSoundEnabled, .menuBarNotificationDuration,
      ])
  }

  /// `all` は SettingID の全 case を過不足なく含む。`rootOrder` はその部分集合で、差は
  /// **root に行を持たない項目の明示リスト**（`nonRootIDs`）とちょうど一致する
  /// ——「rootOrder が全 case を含む」を単に緩めると、行の書き漏れが検出されなくなる。
  func testAllCoversEverySettingIDAndRootOrderIsAllMinusTheNonRootSet() {
    let allIDs = Set(SettingID.allCases)
    XCTAssertEqual(Set(SettingsRegistry.all.map(\.id)), allIDs, "all が全 case を含む")
    XCTAssertEqual(
      SettingsRegistry.nonRootIDs,
      [
        .notificationSoundCustomDone, .notificationSoundCustomWaiting,
        .notificationSoundCustomWaitingSameAsDone,
      ], "root に出さないのは、カスタム設定サブでだけ編集する音源 3 件だけ")
    XCTAssertEqual(
      Set(SettingsRegistry.rootOrder.map(\.id)), allIDs.subtracting(SettingsRegistry.nonRootIDs),
      "rootOrder は非掲載を除く全 case をちょうど覆う")
    XCTAssertEqual(
      SettingsRegistry.rootOrder.count,
      SettingID.allCases.count - SettingsRegistry.nonRootIDs.count,
      "rootOrder に重複は無い")
  }
}

import AppKit
import XCTest

@testable import Orbe

/// NSWindow 背景透過の橋渡し（WindowController+Opacity）の検証。
///
/// 純粋な透過判定（`shouldBeTranslucent`）は値/フルスクリーン別に固定する。
/// 実 window への適用（`syncWindowOpacity` → `window.isOpaque`）は WindowController の構築を要し、
/// **libghostty ランタイムを起動する**（GhosttyKit 必須）。設定は in-memory SSOT（`settingsStore`）を通す。
final class WindowControllerOpacityTests: XCTestCase {

  private var tempSettings: URL!
  private var tempAppState: URL!
  private var tempWorkspaces: URL!
  private var tempGuiConf: URL!

  override func setUp() {
    super.setUp()
    let dir = FileManager.default.temporaryDirectory
    tempSettings = dir.appendingPathComponent("orbe-opacity-settings-\(UUID().uuidString).json")
    tempAppState = dir.appendingPathComponent("orbe-opacity-appstate-\(UUID().uuidString).json")
    tempWorkspaces = dir.appendingPathComponent("orbe-opacity-ws-\(UUID().uuidString).json")
    tempGuiConf = dir.appendingPathComponent("orbe-opacity-gui-\(UUID().uuidString).conf")
    SettingsPersistence.fileURLOverride = tempSettings
    AppStatePersistence.fileURLOverride = tempAppState
    WorkspacePersistence.fileURLOverride = tempWorkspaces
    GuiConfig.fileURLOverride = tempGuiConf
  }

  override func tearDown() {
    NSApp.appearance = nil  // theme テストの外観強制をプロセスグローバルへ残さない
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    WorkspacePersistence.fileURLOverride = nil
    GuiConfig.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempSettings)
    try? FileManager.default.removeItem(at: tempAppState)
    try? FileManager.default.removeItem(at: tempWorkspaces)
    try? FileManager.default.removeItem(at: tempGuiConf)
    super.tearDown()
  }

  /// global 層をディスクへ書く（WindowController 起動時に settingsStore が読む）。
  private func saveGlobal(_ mutate: (inout SettingsLayer) -> Void) {
    var l = SettingsLayer()
    mutate(&l)
    SettingsPersistence.saveGlobal(l)
  }

  /// WS 上書き層を組む。
  private func override(_ mutate: (inout SettingsLayer) -> Void) -> SettingsLayer {
    var l = SettingsLayer()
    mutate(&l)
    return l
  }

  // MARK: - 純粋な透過判定（libghostty 非依存）

  func testShouldBeTranslucentByValueAndFullScreen() {
    XCTAssertTrue(WindowController.shouldBeTranslucent(percent: 90, isFullScreen: false), "90%→透過")
    XCTAssertTrue(
      WindowController.shouldBeTranslucent(percent: 20, isFullScreen: false), "下端 20%→透過")
    XCTAssertFalse(
      WindowController.shouldBeTranslucent(percent: 100, isFullScreen: false), "100%→不透明")
    XCTAssertFalse(
      WindowController.shouldBeTranslucent(percent: 90, isFullScreen: true), "フルスクリーンは常に不透明")
  }

  // MARK: - 実 window への適用（GhosttyKit 必須）

  /// 既定（settings 未設定＝既定 95%）で起動すると窓は非不透明（背景が透ける）。
  func testDefaultSettingAppliesTranslucentWindow() {
    let wc = WindowController()
    XCTAssertFalse(wc.window.isOpaque, "既定 95%<100・非フルスクリーン → isOpaque=false")
  }

  /// 100%（完全不透明）を保存して起動すると窓は不透明。
  func testFullyOpaqueSettingAppliesOpaqueWindow() {
    saveGlobal { $0[SettingKeys.backgroundOpacity] = 100 }
    let wc = WindowController()
    XCTAssertTrue(wc.window.isOpaque, "100% → isOpaque=true")
  }

  /// settings 変更（in-memory SSOT）後に syncWindowOpacity を呼ぶと窓透過が再適用される。
  func testSyncReappliesAfterSettingsChange() {
    let wc = WindowController()
    XCTAssertFalse(wc.window.isOpaque, "起動時（既定 95%）は透過")
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.backgroundOpacity, 100))
    wc.syncWindowOpacity()
    XCTAssertTrue(wc.window.isOpaque, "100% へ変更後の再適用で不透明")
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.backgroundOpacity, 80))
    wc.syncWindowOpacity()
    XCTAssertFalse(wc.window.isOpaque, "80% へ変更後の再適用で再び透過")
  }

  // MARK: - chrome 各面へ配る透過ホルダーへの結線

  func testDefaultLaunchWiresChromeTranslucencyHolder() {
    let wc = WindowController()
    XCTAssertTrue(wc.chromeTranslucency.translucent, "既定 95%<100 → chrome も透過")
    XCTAssertEqual(
      wc.chromeTranslucency.effectiveOpacity, 0.95, accuracy: 0.0001, "既定 95% → 0.95 へスケール")
    XCTAssertTrue(wc.chromeTranslucency.blur, "blur 既定 true → すりガラス有り")
  }

  func testSyncReappliesChromeTranslucencyFromSettings() {
    saveGlobal {
      $0[SettingKeys.backgroundOpacity] = 80
      $0[SettingKeys.backgroundBlur] = true
    }
    let wc = WindowController()
    wc.syncWindowOpacity()
    XCTAssertTrue(wc.chromeTranslucency.translucent, "80% → 透過")
    XCTAssertEqual(wc.chromeTranslucency.effectiveOpacity, 0.8, accuracy: 0.0001, "80% → 0.8")
    XCTAssertTrue(wc.chromeTranslucency.blur, "backgroundBlur=true が settings 由来で通る")

    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.backgroundOpacity, 100))
    wc.syncWindowOpacity()
    XCTAssertFalse(wc.chromeTranslucency.translucent, "100% → 非透過へ畳む")
    XCTAssertEqual(wc.chromeTranslucency.effectiveOpacity, 1, "100% → 1.0")
    XCTAssertFalse(wc.chromeTranslucency.blur, "不透明時は blur 希望でも false へ畳む")
  }

  // MARK: - workspace 上書きが実効設定を駆動する

  func testWorkspaceOverrideDrivesWindowOpacity() {
    saveGlobal { $0[SettingKeys.backgroundOpacity] = 100 }  // global＝不透明
    let wc = WindowController()
    wc.current.settingsOverride = override { $0[SettingKeys.backgroundOpacity] = 80 }  // WS 上書き＝透過
    wc.syncWindowOpacity()
    XCTAssertFalse(wc.window.isOpaque, "workspace 上書き 80% が global 100% を上書きして透過")
  }

  func testActiveEffectiveTracksActiveWorkspaceOverride() {
    saveGlobal { $0[SettingKeys.backgroundOpacity] = 100 }  // global 既定
    let wc = WindowController()
    wc.current.settingsOverride = override { $0[SettingKeys.backgroundOpacity] = 80 }
    XCTAssertEqual(
      wc.activeEffectiveSettings()[SettingKeys.backgroundOpacity], 80, "アクティブ WS の上書きを反映")

    wc.createWorkspace(name: "other")  // 上書き無しの新 WS がアクティブ
    XCTAssertEqual(
      wc.activeEffectiveSettings()[SettingKeys.backgroundOpacity], 100, "上書き無し WS は global を継承")
    wc.current.settingsOverride = override { $0[SettingKeys.backgroundOpacity] = 50 }
    XCTAssertEqual(
      wc.activeEffectiveSettings()[SettingKeys.backgroundOpacity], 50, "新 WS 自身の上書きへ")

    wc.switchWorkspace(to: 0)  // 最初の WS へ戻す
    XCTAssertEqual(
      wc.activeEffectiveSettings()[SettingKeys.backgroundOpacity], 80, "切替で元 WS の上書きへ追従")
  }

  /// devFeaturesEnabled の WS 上書きが右バー gate（`wc.devFeaturesEnabled`）を実効値へ駆動し、
  /// WS 切替で追従する（headline 挙動変更②）。この結線が切れると applyActiveWorkspaceConfig の
  /// gate 再評価が死んでも他テストは緑のままになるため、切替の両向きを固定する。
  func testDevFeaturesGateTracksActiveWorkspaceOverride() {
    saveGlobal { $0[SettingKeys.devFeaturesEnabled] = false }  // global＝gate off
    let wc = WindowController()
    XCTAssertFalse(wc.devFeaturesEnabled, "global false → gate off")

    wc.current.settingsOverride = override { $0[SettingKeys.devFeaturesEnabled] = true }
    wc.applyActiveWorkspaceConfig()
    XCTAssertTrue(wc.devFeaturesEnabled, "WS 上書き true が右バー gate を on にする")

    wc.createWorkspace(name: "other")  // 上書き無しの新 WS がアクティブ
    XCTAssertFalse(wc.devFeaturesEnabled, "上書き無し WS は global（off）へ戻る")

    wc.switchWorkspace(to: 0)  // 元 WS へ戻す
    XCTAssertTrue(wc.devFeaturesEnabled, "切替で元 WS の上書き（on）へ追従")
  }

  /// ディスクに保存された settingsOverride が起動復元で実効設定へ結線される。
  func testRestoresWorkspaceOverrideFromDiskOnLaunch() {
    saveGlobal { $0[SettingKeys.backgroundOpacity] = 100 }  // global＝不透明
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: 0,
        workspaces: [
          WorkspaceState(
            name: "alpha", rootPath: "/tmp", activeTab: 0,
            tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)],
            settingsOverride: override { $0[SettingKeys.backgroundOpacity] = 80 })  // WS 上書き＝透過
        ]))
    let wc = WindowController()  // 上記をディスクから復元
    XCTAssertEqual(
      wc.activeEffectiveSettings()[SettingKeys.backgroundOpacity], 80, "復元した WS 上書きが実効設定へ結線される")
    wc.syncWindowOpacity()
    XCTAssertFalse(wc.window.isOpaque, "復元した実効 80% が窓透過を駆動する")
  }

  /// 初回起動（workspaces.json なし・復元なし）でも反映集約点を通り、gui.conf に常時 emit の
  /// 2 行（emoji-font の font-codepoint-map → theme 定数行）が載る。
  func testFreshLaunchWritesThemeConstantLine() {
    _ = WindowController()
    XCTAssertEqual(
      guiConfContent(),
      "font-codepoint-map = \(EmojiPresentationRanges.confValue)=Noto Color Emoji\n"
        + "theme = light:OrbeLight,dark:OrbeDark\n")
  }

  /// テーマ設定（外観スイッチ）が反映集約点で `NSApp.appearance` を駆動する。
  func testThemeSettingDrivesAppAppearance() {
    saveGlobal { $0[SettingKeys.theme] = .dark }
    let wc = WindowController()
    XCTAssertEqual(NSApp.appearance?.name, .darkAqua, "Dark → アプリ全体を darkAqua へ固定")
    wc.settingsStore.applyGlobal(SettingChange(SettingKeys.theme, ThemeMode.auto))
    wc.applyActiveWorkspaceConfig()
    XCTAssertNil(NSApp.appearance, "Auto（明示）→ nil（OS の外観設定へ追従）")
    wc.settingsStore.applyGlobal(SettingChange(id: .theme, value: nil))  // 未設定へ
    wc.applyActiveWorkspaceConfig()
    XCTAssertNil(NSApp.appearance, "未設定 → 既定 .auto で nil のまま")
  }

  /// 上書きを持つ WS から新規 WS を作ると、実効設定は global へ戻り生成 conf も global で再生成される。
  func testCreateWorkspaceRegeneratesConfigToGlobal() {
    saveGlobal { $0[SettingKeys.fontSize] = 12 }  // global
    let wc = WindowController()
    wc.current.settingsOverride = override { $0[SettingKeys.fontSize] = 30 }  // WS0 上書き
    wc.applyActiveWorkspaceConfig()
    let constLines =
      "font-codepoint-map = \(EmojiPresentationRanges.confValue)=Noto Color Emoji\n"
      + "theme = light:OrbeLight,dark:OrbeDark\n"
    XCTAssertEqual(guiConfContent(), "font-size = 30\n" + constLines, "上書き WS では生成 conf が 30")
    wc.createWorkspace(name: "other")  // 上書き無しの新 WS がアクティブに
    XCTAssertEqual(
      guiConfContent(), "font-size = 12\n" + constLines,
      "新 WS は global 継承——生成 conf が 12 へ再生成される（前 WS の 30 を持ち越さない）")
  }

  private func guiConfContent() -> String {
    guard let url = GuiConfig.fileURLOverride else { return "<no-url>" }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? "<no-file>"
  }
}

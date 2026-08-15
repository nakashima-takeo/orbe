import OrbeSound
import SwiftUI
import XCTest

@testable import Orbe

/// 設定パレット系の flow（ファイル分割の拡張。本体の型サイズ上限を守るため +Update と同じ分け方）。
/// 撮り方・出力先は本体（`DesignFlowSnapshotTests`）の `flow` を共有する。
private let settingsFlowCardSize = NSSize(width: 500, height: 320)

extension DesignFlowSnapshotTests {
  /// Settings パレット（Cmd+,）: root（スコープ行＋7 設定行）→ テーマ行で潜る（Auto/Dark/Light の固定3択）
  /// → Dark を選び root へ → 再度テーマへ潜る → agent サブパレット。
  /// 状態は本物の SettingsPaletteModel が render へ立て下げる（mode 遷移・breadcrumb・hint・● 印が画に出る）。
  /// 再訪（theme_again）は「● と選択色が現在値 Dark の行に揃って乗る」＝先頭行に戻らないことを画で見せる。
  func testSettingsPalette() throws {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    global[SettingKeys.defaultAgent] = "claude"
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global),
      fontNames: ["Menlo", "Monaco", "SF Mono"],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja))
    try flow(
      "settings_palette", size: settingsFlowCardSize,
      render: { paletteSnapshot(settings.render, canvas: settingsFlowCardSize) },
      steps: [
        // スコープ / フォントサイズ / 背景の不透明度 / 背景のブラー / カーソルの点滅 / テーマ / エージェント / フォント / タブタイトルのフォント の 9 行
        ("root", {}),
        (
          "theme",
          {  // テーマ行（index 5）で潜る（breadcrumb「‹ テーマ」＋固定3択・● が実効値 Auto を指す）
            settings.render.selected = 5
            settings.render.onActivate()
          }
        ),
        (
          "theme_dark",
          {  // Dark を選んで確定 → root へ戻りテーマ行が Dark になる
            settings.render.onDown()
            settings.render.onActivate()
          }
        ),
        (
          "theme_again",
          {  // 再びテーマへ潜る（● と選択色が現在値 Dark の行に揃う＝先頭 Auto に戻らない）
            settings.render.onActivate()
          }
        ),
        (
          "agent",
          {  // エージェント行（index 6）で潜る（● と選択色が解決済みデフォルトを指す）
            settings.render.onEscape()  // theme → root（テーマ行に選択が復元される）
            settings.render.selected = 6
            settings.render.onActivate()  // root → agent
          }
        ),
        (
          "font",
          {  // フォント行（index 7）で潜る（先頭＝既定行・全行に ●／2 スペースのプレフィクス）
            settings.render.onEscape()  // agent → root
            settings.render.selected = 7
            settings.render.onActivate()  // root → font
          }
        ),
      ])
  }

  /// Settings パレット WS 上書き: global スコープで「（この WS では …）」注記が付いた長い root 行、
  /// スコープ反転で「（継承）」＋淡色の行、長いフォント名を並べた font サブ（折返し・省略の見え方）。
  /// 行が長くなる最悪条件（注記付き root・長名フォント）を張り、収まりと注記のコントラストを撮る。
  func testSettingsPaletteOverride() throws {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = true
    global[SettingKeys.defaultAgent] = "claude"
    var override = SettingsLayer()
    override[SettingKeys.fontSize] = 16
    override[SettingKeys.backgroundOpacity] = 75
    override[SettingKeys.theme] = .dark
    override[SettingKeys.fontFamily] = "JetBrainsMono Nerd Font Mono"
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(scope: .global, global: global, override: override),
      fontNames: [
        "JetBrainsMono Nerd Font Mono", "0xProto Nerd Font Propo", "Menlo", "SF Mono",
      ],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja))
    let overrideStage = NSSize(width: 500, height: 360)
    try flow(
      "settings_palette_override", size: overrideStage,
      render: { paletteSnapshot(settings.render, canvas: overrideStage) },
      steps: [
        ("global", {}),  // 上書き中の 4 行に「（この WS では …）」注記が付く
        (
          "workspace",
          {  // スコープ行（index 0）を反転 → 未上書き行は「（継承）」＋淡色
            settings.render.selected = 0
            settings.render.onActivate()
          }
        ),
        (
          "font",
          {  // WS スコープの font サブ（先頭＝継承行・長名フォントの収まり）
            settings.render.selected = 7
            settings.render.onActivate()
          }
        ),
      ])
  }

  /// Settings パレット通知音: root → 潜る（入場は無音＝EQ 無し）→ ↓ で試聴（EQ 点灯）→ ⇥ で対象反転
  /// （セグメントの塗りが移り EQ が琥珀へ）→ セグメントのクリックで完了へ戻る → root の音量行で `→`。
  /// アクションで初めて現れる状態（EQ の点灯・対象の反転）を撮るのがここの役目。
  /// 最後の 1 枚は、試聴の 1 経路がサブパレットだけでなく root の音量行にも同じ EQ を出すことを画で押さえる。
  func testSettingsPaletteSound() throws {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.defaultAgent] = "claude"
    global[SettingKeys.notificationSound] = NotificationSound.glass
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global),
      fontNames: ["Menlo", "Monaco", "SF Mono"],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja))
    // 撮影中に鳴り終わりで EQ が消えないよう消灯予約を止める（`pulse` は 0.26 秒で、
    // `renderPNG` が回す RunLoop 0.2 秒との差は 60ms しかない）。
    settings.schedulePreviewEnd = { _, _ in }
    let soundStage = NSSize(width: 500, height: 460)
    try flow(
      "settings_palette_sound", size: soundStage,
      render: { paletteSnapshot(settings.render, canvas: soundStage) },
      steps: [
        ("root", {}),
        (
          "sound",
          {  // 通知音行（index 12）で潜る（入場では鳴らない＝EQ は出ない・セグメントは「完了」）
            settings.render.selected = 12
            settings.render.onActivate()
          }
        ),
        ("preview", { settings.render.onDown() }),  // 試聴 → その行の右端に EQ（完了＝緑）
        ("waiting", { _ = settings.render.onTab() }),  // 対象を反転 → 塗りが移り EQ が琥珀へ
        ("tab_click", { settings.render.onTapSegment(0) }),  // クリックで完了へ戻す
        (
          "root_volume",
          {  // root へ戻り音量行（index 13）で `→`。値が動いて完了音が鳴り、EQ が root の行にも出る
            settings.render.onEscape()  // 通知音サブ → root
            settings.render.selected = 13
            _ = settings.render.onRight()
          }
        ),
      ])
  }

  /// Settings パレット agent 空状態: agent 検出ゼロでサブリストへ潜り、情報行（選択不可・text.muted）が
  /// 起動パレットの CLI 検出ゼロと同じ様式で出るかを撮る。テーマ行と違い ● も実行対象も無い。
  func testSettingsPaletteAgentEmpty() throws {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global), fontNames: [], agents: [],
      localization: LocalizationStore(language: .ja))
    try flow(
      "settings_palette_agent_empty", size: settingsFlowCardSize,
      render: { paletteSnapshot(settings.render, canvas: settingsFlowCardSize) },
      steps: [
        ("root", {}),
        (
          "agent_empty",
          {  // エージェント行（index 6）で潜る → 検出ゼロの情報行のみ
            settings.render.selected = 6
            settings.render.onActivate()
          }
        ),
      ])
  }

}

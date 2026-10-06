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
  /// （セグメントの塗りが移り EQ が琥珀へ）→ セグメントのクリックで完了へ戻る → カスタム行へ移り
  /// `→` で設定サブ → 取り込み成功（補足が元ファイル名へ変わり、確認再生の EQ が点く）→ トグル反転 →
  /// 取り込み失敗（面の先頭に理由 1 行＝danger）→ カスタムを確定して root の音量行で `→`。
  /// アクションで初めて現れる状態（EQ の点灯・対象の反転・取り込みの成否）を撮るのがここの役目。
  /// 最後の 1 枚は、root の通知音行が「カスタム」を名乗ることと、試聴の 1 経路がサブパレットだけで
  /// なく root の音量行にも同じ EQ を出すことを一緒に画で押さえる。
  func testSettingsPaletteSound() throws {
    let settings = soundFlowModel()
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
      ] + customSoundSteps(settings))
  }

  /// 通知音 flow のうちカスタム音源の段（一覧のカスタム行 → 設定サブ → 確定して root へ）。
  /// 取り込みはファイル選択と取り込み器の seam を差し替えて起こす（実ファイルもパネルも要らない）。
  private func customSoundSteps(_ settings: SettingsPaletteModel)
    -> [(label: String, action: () -> Void)]
  {
    let doneName = "sonar-ping.mp3"
    let badName = "field-recording-2026-08-21-take-07-master.aiff"
    func stub(_ name: String, _ result: Result<CustomSoundSource, SoundFileImporter.ImportError>) {
      settings.pickSoundFile = { URL(fileURLWithPath: "/tmp/" + name) }
      settings.importSoundFile = { _ in result }
    }
    return [
      (
        "custom",
        {  // カスタム行（index 13・まだ未取り込み＝補足は「未設定」）から `→` で設定サブへ
          settings.render.selected = 13
          _ = settings.render.onRight()
        }
      ),
      (
        "imported",
        {  // 完了の音源で取り込み成功 → 補足が元ファイル名へ変わり確認再生の EQ が点く
          stub(
            doneName, .success(CustomSoundSource(file: "9f2c.wav", name: doneName, duration: 1.83)))
          settings.render.onActivate()
        }
      ),
      (
        "same_as_done_off",
        {  // トグルを反転 → 入力待ちの行が「（完了と同じ）」の無効行から編集できる行へ変わる
          settings.render.selected = 2
          settings.render.onActivate()
        }
      ),
      (
        "import_failed",
        {  // 取り込み失敗 → 面の先頭に理由 1 行（danger）。長いファイル名で折返しの収まりも見る
          stub(badName, .failure(.unreadable))
          settings.render.selected = settings.soundCustomRowIndex(.doneSource)
          settings.render.onActivate()
        }
      ),
      (
        "root_volume",
        {  // `←` で通知音サブ（選択はカスタム行に復元）→ `↵` で確定して root へ。root の通知音行は
          // 値が「カスタム」に変わっている。続けて音量行（index 13）で `→`。値が動いて完了音が鳴り、
          // EQ が root の行にも出る
          settings.render.onEscape()  // カスタム設定サブ → 通知音サブ
          settings.render.onActivate()  // カスタム行を確定 → root へ
          settings.render.selected = 13
          _ = settings.render.onRight()
        }
      ),
    ]
  }

  /// 通知音 flow の実モデル。撮影中に鳴り終わりで EQ が消えないよう消灯予約を止める
  /// （`pulse` は 0.26 秒で、`renderPNG` が回す RunLoop 0.2 秒との差は 60ms しかない）。
  private func soundFlowModel() -> SettingsPaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.defaultAgent] = "claude"
    global[SettingKeys.notificationSound] = .preset(.glass)
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global),
      fontNames: ["Menlo", "Monaco", "SF Mono"],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja))
    settings.schedulePreviewEnd = { _, _ in }
    return settings
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

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
    global[SettingKeys.devFeaturesEnabled] = true
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global),
      fontNames: ["Menlo", "Monaco", "SF Mono"],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja))
    try flow(
      "settings_palette", size: settingsFlowCardSize, render: { paletteSnapshot(settings.render) },
      steps: [
        // スコープ / フォントサイズ / 背景の不透明度 / 背景のブラー / カーソルの点滅 / テーマ / エージェント / フォント / 開発中の機能を有効化 の 9 行
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
    global[SettingKeys.devFeaturesEnabled] = true
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
    try flow(
      "settings_palette_override", size: NSSize(width: 500, height: 360),
      render: { paletteSnapshot(settings.render) },
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

  /// Settings パレット worktree 作成先（textInput 編集面）: root の現在テンプレ値表示 → 潜って編集面
  /// （プリフィル＋ライブ展開プレビュー行）→ 別の妥当テンプレを打鍵しプレビュー追従 → 未知トークンで
  /// フッター赤インラインエラー → {slug} 欠落エラー。既存 stepper/toggle 行と同じトーンで並ぶかを撮る。
  func testSettingsPaletteWorktree() throws {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    global[SettingKeys.defaultAgent] = "claude"
    global[SettingKeys.devFeaturesEnabled] = true
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global),
      fontNames: ["Menlo", "Monaco", "SF Mono"],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja),
      worktreePreviewRoot: "~/dev/orbe")
    let worktreeRow = 12  // scope(0) + 12 設定行のうち worktreePath は末尾
    try flow(
      "settings_palette_worktree", size: NSSize(width: 500, height: 360),
      render: { paletteSnapshot(settings.render) },
      steps: [
        ("root", {}),  // 末尾に「Worktree の作成先  ../{repo}-worktrees/{slug}」
        (
          "editor",
          {  // 潜ると現在テンプレでプリフィル＋展開プレビュー行（作成先 → 絶対パス）
            settings.render.selected = worktreeRow
            settings.render.onActivate()
          }
        ),
        (
          "typed_valid",
          {  // 別の妥当テンプレを打鍵 → プレビューが追従する
            settings.render.query = "~/worktrees/{repo}/{slug}"
            settings.render.onQueryChange()
          }
        ),
        (
          "invalid_token",
          {  // 未知トークン {branch} → フッターに赤インラインエラー・プレビュー消える
            settings.render.query = "../{repo}-worktrees/{branch}"
            settings.render.onQueryChange()
          }
        ),
        (
          "invalid_missing_slug",
          {  // {slug} 欠落 → 別のエラー文言（衝突警告）
            settings.render.query = "../{repo}-worktrees"
            settings.render.onQueryChange()
          }
        ),
      ])
  }

  /// Settings パレット worktree 編集面の小窓耐性: 幅 380 の窄い窓で、長い絶対パスのプレビュー行と
  /// エラー文言がカード/入力欄を破綻させず 1 行省略・折返しで収まるかを撮る（最悪条件の張り込み）。
  func testSettingsPaletteWorktreeNarrow() throws {
    var global = SettingsLayer()
    global[SettingKeys.devFeaturesEnabled] = true
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global),
      fontNames: [], agents: [],
      localization: LocalizationStore(language: .ja),
      worktreePreviewRoot: "~/Developer/very-long-repository-name")
    let worktreeRow = 12
    try flow(
      "settings_palette_worktree_narrow", size: NSSize(width: 380, height: 340),
      render: { paletteSnapshot(settings.render) },
      steps: [
        (
          "editor_long",
          {  // 潜って長い絶対パスのプレビュー（窄い窓で 1 行に収まるか・省略の見え方）
            settings.render.selected = worktreeRow
            settings.render.onActivate()
            settings.render.query = "~/Developer/deeply/nested/worktrees/{repo}/{slug}"
            settings.render.onQueryChange()
          }
        ),
        (
          "error_long",
          {  // 長い未知トークンエラーがフッターで折返し・カードを割らない
            settings.render.query = "../{repo}-worktrees/{feature-branch-name}"
            settings.render.onQueryChange()
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
    global[SettingKeys.devFeaturesEnabled] = true
    let settings = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global), fontNames: [], agents: [],
      localization: LocalizationStore(language: .ja))
    try flow(
      "settings_palette_agent_empty", size: settingsFlowCardSize,
      render: { paletteSnapshot(settings.render) },
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

import SwiftUI
import XCTest

@testable import Orbe

/// chrome の「振る舞い」を本物のアクションメソッドで駆動し、各ステップを連番 PNG にするフィルムストリップ。
/// gallery（fixture で状態を置く静止）と 1 点だけ違う: 遷移後の状態を手で置かず、アクションが状態を生む過程を撮る。
/// アクションが壊れればフィルムストリップに出る。dark のみ（振る舞いに集中・見た目の Light/Dark は gallery が担う）。
/// 通常の `swift test` を汚さないよう `ORBE_FLOWS=1` でゲート。出力先 <repo>/.preview/flows（gitignore 済）。
/// flow ごとに独立した test メソッドへ分け、`--filter "…/test<Flow>"` で 1 本だけ撮れる。
@MainActor
final class DesignFlowSnapshotTests: SnapshotTestCase {

  private var dir: URL!
  private let cardSize = NSSize(width: 500, height: 320)

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["ORBE_FLOWS"] == nil,
      "flow 描画は ORBE_FLOWS=1 のときだけ実行する")
    dir = previewDir("flows")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  /// アクションを 1 つ呼んでから現状の view を撮る、を順に繰り返し連番 PNG を書く。
  /// `name_<NN>_<label>.png` で出力。fixture と違い、状態はアクションが生む（壊れたら画に出る）。
  private func flow<V: View>(
    _ name: String, size: NSSize, render: () -> V,
    steps: [(label: String, action: () -> Void)]
  ) throws {
    for (idx, step) in steps.enumerated() {
      step.action()
      let data = try XCTUnwrap(renderPNG(render(), size: size, dark: true))
      let url = dir.appendingPathComponent(String(format: "%@_%02d_%@.png", name, idx, step.label))
      try data.write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }

  // MARK: - 各 flow

  /// パレット選択移動: 本物の move() が enabled 行だけ巡回し情報行を飛ばす過程を撮る。
  /// 情報行（CLI が見つかりません）は選択対象外。下へ進むと codex→agy と飛び、末尾から先頭へ巡回する。
  func testPaletteNav() throws {
    let nav = PaletteModel()
    nav.hint = "↵ 起動   → 詳細   esc 閉じる"
    nav.rows = [
      .init(label: "● claude", chevron: true),
      .init(label: "  codex", chevron: true),
      .init(label: "CLI が見つかりません", enabled: false),
      .init(label: "  agy", chevron: true),
    ]
    try flow(
      "palette_nav", size: cardSize, render: { paletteSnapshot(nav) },
      steps: [
        ("start", {}),
        ("down", { nav.move(1) }),  // claude → codex
        ("down", { nav.move(1) }),  // codex → agy（情報行を飛ばす）
        ("down", { nav.move(1) }),  // agy → claude（末尾から巡回）
        ("up", { nav.move(-1) }),  // claude → agy
      ])
  }

  /// AgentPalette ドリルイン: 一覧 → drillIn() で submenu（breadcrumb 付き）→ goBack() で一覧。
  /// 状態は本物のアクションが生む（render は AgentPaletteModel.render を撮る）。
  func testPaletteDrill() throws {
    let agents = [
      AgentCLI(command: "claude", path: "/usr/local/bin/claude"),
      AgentCLI(command: "codex", path: "/usr/local/bin/codex"),
      AgentCLI(command: "agy", path: "/usr/local/bin/agy"),
    ]
    let palette = AgentPaletteModel()
    try flow(
      "palette_drill", size: cardSize, render: { paletteSnapshot(palette.render) },
      steps: [
        ("list", { palette.setAgents(agents, defaultCommand: "claude") }),
        ("drill", { palette.drillIn() }),  // 選択中(claude)の詳細メニューへ潜る
        ("back", { palette.goBack() }),  // 一覧へ戻る
      ])
  }

  /// Onboarding 導入: setCommands(select) → beginInstalling(installing へ) → per-CLI の進捗を進める。
  /// installing → done / failed の遷移が各 CLI で連番に出る。
  func testOnboardingInstall() throws {
    let onboarding = OnboardingModel()
    let commands = ["claude", "codex", "agy"]
    try flow(
      "onboarding_install", size: cardSize, render: { onboardingSnapshot(onboarding) },
      steps: [
        ("select", { onboarding.setCommands(commands) }),
        ("installing", { onboarding.beginInstalling() }),  // 全 CLI を待機で並べる
        ("claude_run", { onboarding.setStatus("claude", .installing) }),
        (
          "claude_done",
          {
            onboarding.setStatus("claude", .done)
            onboarding.setStatus("codex", .installing)
          }
        ),
        (
          "codex_failed",
          {
            onboarding.setStatus("codex", .failed)
            onboarding.setStatus("agy", .installing)
          }
        ),
        ("agy_done", { onboarding.setStatus("agy", .done) }),
      ])
  }

  /// Completion スクロール追従: cap(~5 行)超過の候補を積み、selected を下へ進める。
  /// scrollY は selected から派生するので、選択行が下端フェードの上に保たれて連番に出る。
  func testCompletionScroll() throws {
    let completion = CompletionListModel()
    completion.choices = CompletionList.displayOrdered([
      CompletionChoice(
        value: "status", description: "作業ツリーの状態を表示", insertValue: nil, type: "subcommand"),
      CompletionChoice(
        value: "commit", description: "ステージした変更を記録", insertValue: nil, type: "subcommand"),
      CompletionChoice(
        value: "checkout", description: "ブランチ切替・ファイル復元", insertValue: nil, type: "subcommand"),
      CompletionChoice(value: "main", description: "", insertValue: nil, type: nil),
      CompletionChoice(value: "feature/editor-pane", description: "", insertValue: nil, type: nil),
      CompletionChoice(value: "fix/tab-overflow", description: "", insertValue: nil, type: nil),
      CompletionChoice(value: "release/0.2.0", description: "", insertValue: nil, type: nil),
      CompletionChoice(value: "README.md", description: "", insertValue: nil, type: "file"),
      CompletionChoice(value: "--oneline", description: "", insertValue: nil, type: "option"),
      CompletionChoice(
        value: "--graph", description: "コミットグラフを ASCII で描画", insertValue: nil, type: "option"),
    ])
    try flow(
      "completion_scroll", size: NSSize(width: 320, height: 300),
      render: { completionSnapshot(completion) },
      steps: [
        ("top", { completion.selected = 0 }),
        ("down2", { completion.selected = 2 }),
        ("down4", { completion.selected = 4 }),
        ("down6", { completion.selected = 6 }),
        ("down8", { completion.selected = 8 }),
        ("bottom", { completion.selected = 9 }),
      ])
  }

  /// Workspace 絞り込み: setItems(一覧) → query を変え onQueryChange() で rebuild() を走らせる。
  /// 絞り込みで行が減る／一致なしで create 行が生える／空に戻すと全件、が連番に出る。
  func testWorkspaceFilter() throws {
    let workspace = WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
    let items = [
      WorkspacePaletteModel.Item(
        index: 0, name: "main", isActive: true, dormant: false, agentRollup: [], dir: "/"),
      WorkspacePaletteModel.Item(
        index: 1, name: "infra", isActive: false, dormant: false, agentRollup: [], dir: "/"),
      WorkspacePaletteModel.Item(
        index: 2, name: "archive", isActive: false, dormant: true, agentRollup: [], dir: "/"),
    ]
    try flow(
      "workspace_filter", size: cardSize, render: { paletteSnapshot(workspace.render) },
      steps: [
        ("list", { workspace.setItems(items) }),
        (
          "filter_in",
          {
            workspace.render.query = "in"  // main / infra が残る
            workspace.render.onQueryChange()
          }
        ),
        (
          "create",
          {
            workspace.render.query = "newproj"  // 一致なし → create 行が生える
            workspace.render.onQueryChange()
          }
        ),
        (
          "reset",
          {
            workspace.render.query = ""  // 全件へ戻る
            workspace.render.onQueryChange()
          }
        ),
      ])
  }

  /// Workspace 改名: 一覧 → 行選択 → drillIn（詳細メニュー）→ 改名アクション activate → 改名入力欄。
  /// 入力欄だけのプロンプト（行ゼロ）でカードが空帯を作らず header＋hint に畳まれるかを撮る。
  func testWorkspaceRename() throws {
    let workspace = WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
    let items = [
      WorkspacePaletteModel.Item(
        index: 0, name: "main", isActive: true, dormant: false, agentRollup: [], dir: "/"),
      WorkspacePaletteModel.Item(
        index: 1, name: "infra-experiments", isActive: false, dormant: false, agentRollup: [],
        dir: "/Users/me/code/infra"),
    ]
    try flow(
      "workspace_rename", size: cardSize, render: { paletteSnapshot(workspace.render) },
      steps: [
        ("list", { workspace.setItems(items) }),
        ("select", { workspace.render.selected = 1 }),  // infra-experiments 行へ
        ("submenu", { _ = workspace.render.onRight() }),  // drillIn → 詳細メニュー
        ("rename", { workspace.render.onActivate() }),  // 改名アクション → 入力欄
      ])
  }

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
      "settings_palette", size: cardSize, render: { paletteSnapshot(settings.render) },
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
      "settings_palette_agent_empty", size: cardSize, render: { paletteSnapshot(settings.render) },
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

  /// Workspace 項目過多: setItems(多数) でカードがどう振る舞うか。PaletteCard の行リストは
  /// ScrollView も高さ cap も持たない（completion の capHeight に相当するものが無い）ため、
  /// 項目が増えるとカードが青天井に伸び、ビューポートを超えた行・hint・末尾選択がスクロール不能で
  /// 視界から消える。その overflow を連番で撮る（few → many → 末尾選択が視界外）。
  func testWorkspaceOverflow() throws {
    let names = [
      "main", "infra", "archive", "staging", "prod", "hotfix", "experiment", "docs",
      "sandbox", "review", "release", "backup", "analytics", "mobile", "api", "web", "data", "ml",
    ]
    let items = names.enumerated().map { i, n in
      WorkspacePaletteModel.Item(
        index: i, name: n, isActive: i == 0, dormant: false, agentRollup: [], dir: "/")
    }
    let workspace = WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
    try flow(
      "workspace_overflow", size: NSSize(width: 500, height: 440),
      render: { paletteSnapshot(workspace.render) },
      steps: [
        ("few", { workspace.setItems(Array(items.prefix(4))) }),
        ("many", { workspace.setItems(items) }),  // 18 件 → カードが枠を超える
        ("select_last", { workspace.render.selected = items.count - 1 }),  // 末尾選択は視界外へ
      ])
  }
}

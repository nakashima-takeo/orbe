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
  /// 分割した拡張ファイル（+Settings / +Update）からも使うため internal。
  func flow<V: View>(
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

  /// メニューバー②の到来: 本物の `arrived` / `tick` / `expired` で駆動し（時刻は注入するので
  /// 実時間を待たない）、展開・艶の走査・滞留・収縮の各フレームを撮る。
  /// 01 と 08 が同形で数字だけ違えば「閉じた姿は常に実件数を示す」、開き切りの 04〜06 に数字が
  /// 無ければ「文言表示中は件数を出さない」が画で確かめられる。02 が 01 と同形なのは、到来の
  /// 瞬間に幅も姿も飛ばないこと（1 つのピルに統合した理由そのもの）の証拠。畳まれかけの
  /// 03・07 は件数が途中の濃度で残る——`countFold` は開き具合の関数で、0 になるのは開き切り。
  /// 数字が 2 から 3 へ変わるのは 07（収縮）から。開いていく側はずっと到来時の 2 を見せる。
  func testMenubarArrival() throws {
    let t0 = Date()
    let store = AttentionStore()
    let driver = MenuBarArrivalDriver()
    let seeded = [
      AttentionRow(
        paneId: 9001, workspaceName: "orbe-remote-ios", tabTitle: "CI 修復", state: "done",
        message: "build OK — 変更なし", stateChangedAt: t0.addingTimeInterval(-480)),
      AttentionRow(
        paneId: 9002, workspaceName: "api-gateway", tabTitle: "deploy スクリプト整理",
        state: "waiting", message: "ビルド成果物の掃除方法を選んでください。",
        stateChangedAt: t0.addingTimeInterval(-45)),
    ]
    let arriving = AttentionRow(
      paneId: 9003, workspaceName: "orbe-core", tabTitle: "emit API 移行", state: "waiting",
      message: "Bash の許可が必要です — bin/rails db:migrate", stateChangedAt: t0)
    try flow(
      "menubar_arrival", size: NSSize(width: 420, height: 64),
      render: { menuBarSnapshot(store: store, phase: driver.phase) },
      steps: [
        ("quiet", {}),  // ① 減光 ◐・地なし・数字なし
        ("seeded", { store.apply(rows: seeded) }),  // ③ ◐＋件数 2
        (
          "arrive",
          {
            store.noteTransient(arriving, now: t0)
            driver.arrived(at: t0)
          }
        ),
        (
          "expand_half",
          {
            // 一覧は report 経路の次の coalesce で 3 件へ。開いていく間の②が見せるのは到来した
            // 瞬間の 2 なので、ここで 3 になっても画は動かない（3 が出るのは収縮の 07 から）。
            store.apply(rows: seeded + [arriving])
            driver.tick(now: t0.addingTimeInterval(0.42))
          }
        ),
        ("open", { driver.tick(now: t0.addingTimeInterval(0.84)) }),
        ("gloss_mid", { driver.tick(now: t0.addingTimeInterval(1.75)) }),
        ("dwell", { driver.tick(now: t0.addingTimeInterval(5)) }),
        (
          "collapse_half",
          {
            driver.expired(at: t0.addingTimeInterval(22))
            driver.tick(now: t0.addingTimeInterval(22.3))
          }
        ),
        (
          "closed",
          {
            if driver.tick(now: t0.addingTimeInterval(22.6)) { store.transient = nil }
          }
        ),
      ])
  }

  /// 原典ケース①（待ち 0 件 → 新着 1 件）。②が生きている間ずっと `store.count` は 1 なのに、
  /// 00〜03 のどのコマにも数字が無く、04 で初めて「1」が現れる——これが「開くとき仕舞い、
  /// 閉じながら生まれる」の実体で、②が見せるのが**到来した瞬間の件数**である証拠。
  /// 一覧は展開の途中（02）で 1 件へ追いつくが、画は動かない。
  func testMenubarArrivalFirst() throws {
    let t0 = Date()
    let store = AttentionStore()
    let driver = MenuBarArrivalDriver()
    let arriving = AttentionRow(
      paneId: 9101, workspaceName: "orbe-core", tabTitle: "emit API 移行", state: "waiting",
      message: "Bash の許可が必要です", stateChangedAt: t0)
    try flow(
      "menubar_arrival_first", size: NSSize(width: 420, height: 64),
      render: { menuBarSnapshot(store: store, phase: driver.phase) },
      steps: [
        ("quiet", {}),  // ① 減光 ◐・地なし・数字なし
        (
          "arrive",
          {
            store.noteTransient(arriving, now: t0)  // 到来時の件数は 0
            driver.arrived(at: t0)
          }
        ),
        (
          "expand_half",
          {
            store.apply(rows: [arriving])  // 一覧が 1 件へ追いつく。画は動かない
            driver.tick(now: t0.addingTimeInterval(0.42))
          }
        ),
        ("open", { driver.tick(now: t0.addingTimeInterval(0.84)) }),
        (
          "collapse_half",
          {
            driver.expired(at: t0.addingTimeInterval(22))
            driver.tick(now: t0.addingTimeInterval(22.3))  // ここで初めて「1」が生まれる
          }
        ),
        (
          "closed",
          {
            if driver.tick(now: t0.addingTimeInterval(22.6)) { store.transient = nil }
          }
        ),
      ])
  }
}

/// メニューバーアイテムを bar 相当の地へ右寄せで置いたスナップショット用ビュー。
/// 実メニューバーと同じ ideal サイズで撮るため、幅は content に決めさせる。
private func menuBarSnapshot(store: AttentionStore, phase: MenuBarArrival.Phase) -> some View {
  MenuBarStatusView(store: store, ui: MenuBarUIState(), phase: phase)
    .fixedSize()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    .padding(.horizontal, Theme.Space.phrase)
    .background(Color.theme.bgBase)
}

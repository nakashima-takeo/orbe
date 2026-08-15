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
      "palette_nav", size: cardSize, render: { paletteSnapshot(nav, canvas: cardSize) },
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
      "palette_drill", size: cardSize,
      render: { paletteSnapshot(palette.render, canvas: cardSize) },
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
      CompletionChoice(value: "feature/tab-rename", description: "", insertValue: nil, type: nil),
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
      "workspace_filter", size: cardSize,
      render: { paletteSnapshot(workspace.render, canvas: cardSize) },
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
      "workspace_rename", size: cardSize,
      render: { paletteSnapshot(workspace.render, canvas: cardSize) },
      steps: [
        ("list", { workspace.setItems(items) }),
        ("select", { workspace.render.selected = 1 }),  // infra-experiments 行へ
        ("submenu", { _ = workspace.render.onRight() }),  // drillIn → 詳細メニュー
        ("rename", { workspace.render.onActivate() }),  // 改名アクション → 入力欄
      ])
  }

  /// clean のサブライン: 確認行をチェックするとブランチの扱いが開き、←→ で選び直せる過程を撮る。
  /// **flow が撮るのは遷移**（開く → `削除` を選ぶ → 外して畳む）で、開いた瞬間の静止画は
  /// gallery の `dispatch_clean_subline` が持つ。
  func testCleanSubline() throws {
    let palette = DesignSceneFixtures.dispatchCleanModel()
    let clean = palette.clean
    // 最初の確認行（ブランチを持つ＝開くものがある行）へ本物の move() で降りる。
    let target = clean.selectableRows.firstIndex { $0.group == .caution && $0.branch != nil } ?? 0
    try flow(
      "clean_subline", size: NSSize(width: 640, height: 520),
      render: {
        ZStack {
          BackgroundGlow()
          DispatchOverlay(model: palette)
        }
      },
      steps: [
        ("start", {}),
        ("cursor", { for _ in 0..<target { clean.move(1) } }),
        ("check", { clean.toggleAtCursor() }),  // チェックした瞬間にサブラインが開く
        ("delete", { clean.chooseBranch(.delete) }),
        ("keep", { clean.chooseBranch(.keep) }),
        ("uncheck", { clean.toggleAtCursor() }),  // 外すとサブラインごと畳む
      ])
  }

  /// 低い窓での収まり: 器が窓高からカードの上限を逆算し、**縮むのは行リストだけ**という契約を撮る。
  /// overlay ごと撮るのは、上端アンカーが 66:16 の比を保って譲る様子がここでしか出ないため。
  /// few（3 件・内容にハグ）→ many（18 件・窓に合わせてリストが縮む）→ select_last（末尾選択に
  /// 内部スクロールが追従）→ shrink（更に低いステージでも選択行とヒントが残る）。
  func testPaletteLowWindow() throws {
    let names = [
      "main", "infra", "archive", "staging", "prod", "hotfix", "experiment", "docs",
      "sandbox", "review", "release", "backup", "analytics", "mobile", "api", "web", "data", "ml",
    ]
    let items = names.enumerated().map { i, n in
      WorkspacePaletteModel.Item(
        index: i, name: n, isActive: i == 0, dormant: false, agentRollup: [], dir: "/")
    }
    let workspace = WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
    // shrink の段だけ窓を下げる。`flow` は 1 本の size で撮るので、キャンバスは 300 のまま
    // 窓のステージだけ縮めて上詰めで置く——余った下帯が「窓が縮んだ」ことをそのまま見せる。
    let canvas = NSSize(width: 500, height: 300)
    var stage = canvas
    try flow(
      "palette_low_window", size: canvas,
      render: {
        paletteOverlaySnapshot(workspace.render, canvas: stage)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .background(Color.theme.bgBase)
      },
      steps: [
        // 3 件＋作成導線ならこのステージのリスト上限に収まる＝カードが内容にハグする段。
        ("few", { workspace.setItems(Array(items.prefix(3))) }),
        ("many", { workspace.setItems(items) }),  // 18 件 → リストが窓の残りまで縮む
        ("select_last", { workspace.render.selected = items.count - 1 }),  // 末尾へ（スクロール追従）
        ("shrink", { stage = NSSize(width: 500, height: 240) }),  // 更に低い窓でも選択行とヒントが残る
      ])
  }

}

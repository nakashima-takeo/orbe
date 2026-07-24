import SwiftUI
import XCTest

@testable import Orbe

/// デザイン部品ライブラリの「見て直す」ループ用ギャラリー・スナップショッタ。
/// 各部品を fixture で状態を置いて Light/Dark の見た目を撮る（静止・アサートはしない・AI/人間が見る）。
/// 振る舞い（アクションが状態を生む過程）は `DesignFlowSnapshotTests` が連番で撮る。
/// 低レベル描画・出力先・カードの地は `SnapshotTestCase`（基底）が持つ。
/// 通常の `swift test` を汚さないよう `ORBE_GALLERY=1` でゲート。
/// 出力先: <repo>/.preview/gallery（gitignore 済）。$ORBE_GALLERY_DIR で上書き可。
@MainActor
final class DesignGallerySnapshotTests: SnapshotTestCase {

  func testRenderGallery() throws {
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["ORBE_GALLERY"] == nil,
      "ギャラリー描画は ORBE_GALLERY=1 のときだけ実行する")

    let dir = outputDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let size = NSSize(width: 480, height: 520)
    for dark in [true, false] {
      let data = try XCTUnwrap(renderPNG(GalleryView(), size: size, dark: dark))
      let url = dir.appendingPathComponent(dark ? "components_dark.png" : "components_light.png")
      try data.write(to: url)
      print("[gallery] wrote \(url.path)")
    }

    // Onboarding カード（select / installing）を別 PNG で。
    let selectModel = OnboardingModel()
    selectModel.agentCommands = ["claude", "codex", "agy"]
    selectModel.selected = 0
    let cardSize = NSSize(width: 500, height: 320)
    try writePNG(
      onboardingSnapshot(selectModel), size: cardSize, name: "onboarding_select.png", dir: dir)

    let detectingModel = OnboardingModel()
    detectingModel.detecting = true
    try writePNG(
      onboardingSnapshot(detectingModel), size: cardSize, name: "onboarding_detecting.png", dir: dir
    )

    let installModel = OnboardingModel()
    installModel.agentCommands = ["claude", "codex", "agy"]
    installModel.phase = .installing
    installModel.statuses = ["claude": .done, "codex": .installing, "agy": .failed]
    try writePNG(
      onboardingSnapshot(installModel), size: cardSize, name: "onboarding_installing.png", dir: dir)

    // 初回言語選択カード（ja / en）。雛形 Onboarding と同じ器・幅・余白で、各言語が現在言語で自らを描く。
    try writePNG(
      languageSelectSnapshot(.ja), size: cardSize, name: "language_select_ja.png", dir: dir)
    try writePNG(
      languageSelectSnapshot(.en), size: cardSize, name: "language_select_en.png", dir: dir)

    try renderPaletteSnapshots(dir: dir, cardSize: cardSize)

    try renderDispatchSnapshots(dir: dir)

    // SearchBar（empty / typing / no-match / match / overflow）。
    try writePNG(
      SearchBarFixtures.gallery(), size: NSSize(width: 320, height: 320),
      name: "searchbar.png", dir: dir)

    try renderCompletionSnapshot(dir: dir)
    try renderEditorPaneSnapshots(dir: dir)
    try renderStatusRowSnapshots(dir: dir)
    try renderWorkspaceCreateSnapshots(dir: dir)
    try renderUpdateSnapshots(dir: dir)
    try renderHelpSnapshots(dir: dir)
  }

  /// Dispatch パレット（実データ形の決定的サンプル・overlay ごと・突合用）。
  /// 多件数は通常/低い窓（360）で cap＋内部スクロール、狭幅（360）で truncate を検証する。
  private func renderDispatchSnapshots(dir: URL) throws {
    func write(_ name: String, _ model: DispatchPaletteModel, _ w: CGFloat, _ h: CGFloat) throws {
      try writePNG(
        ZStack {
          BackgroundGlow()
          DispatchOverlay(model: model)
        }.frame(width: w, height: h),
        size: NSSize(width: w, height: h), name: name, dir: dir)
    }
    try write("dispatch_design.png", DesignSceneFixtures.dispatchModel(), 640, 520)
    try write("dispatch_preparing.png", DesignSceneFixtures.dispatchPreparingModel(), 640, 520)
    try write("dispatch_skeleton.png", DesignSceneFixtures.dispatchSkeletonModel(), 640, 520)
    try write("dispatch_loading.png", DesignSceneFixtures.dispatchLoadingModel(), 640, 520)
    try write("dispatch_gh_missing.png", DesignSceneFixtures.dispatchGhMissingModel(), 640, 520)
    try write("dispatch_filtered.png", DesignSceneFixtures.dispatchFilteredModel(), 640, 520)
    try write("dispatch_many.png", DesignSceneFixtures.dispatchManyModel(), 640, 520)
    try write("dispatch_many_short.png", DesignSceneFixtures.dispatchManyModel(), 640, 360)
    try write("dispatch_narrow.png", DesignSceneFixtures.dispatchManyModel(), 360, 520)
  }

  /// StatusRow（最上段 chrome）の状態。gallery は borderless 窓なので信号機は無く、
  /// タブ・色・shrink・overflow・ストリップを検証する（信号機整列は実窓ハーネスで詰める）。
  /// 実アプリ同様に、design 正典 ステージ同寸（640×520）の BackgroundGlow の上へ重ねて撮る
  /// （TopBar は透明背景で、ambient の減衰はステージ全体の寸法に依存するため帯だけで描かない）。
  private func chromeBand(_ model: StatusRowModel, size: NSSize) -> some View {
    ZStack(alignment: .top) {
      BackgroundGlow()
      StatusRowView(model: model).frame(width: size.width, height: Chrome.barHeight)
    }
    .frame(width: size.width, height: size.height, alignment: .top)
  }

  private func renderStatusRowSnapshots(dir: URL) throws {
    // design 正典 のステージ同寸（chrome 帯 26+28 ＋ 空のターミナル領域）。
    let size = NSSize(width: 640, height: 520)

    // 通常: design 正典 Terminal シーンの fixture（11 タブ・ストリップ 3/1/5/2・cwd なし）。
    let normal = StatusRowModel()
    normal.workspace = "orbe-core"
    normal.titles = [
      "src/renderer", "libghostty", "tests", "docs/spec", "agent-hooks", "state-store",
      "api-docs", "hooks-spec", "perf/batching", "release-0.9", "ci-fix",
    ]
    normal.glyphs = [
      .working, .waiting, nil, .done, .working, .working, .done, .done, nil, .done, .done,
    ]
    normal.active = 0
    normal.rollup = [("working", 3), ("waiting", 1), ("done", 5), ("idle", 2)]
    try writePNG(chromeBand(normal, size: size), size: size, name: "statusrow_normal.png", dir: dir)

    // overflow: 多数タブ＋長いタブ名（maxWidth cap＋shrink＋末尾省略）。状態グリフ各色を巡回。cwd あり。
    let overflow = StatusRowModel()
    overflow.workspace = "infra"
    let glyphCycle: [AgentStateIcon.Kind?] = [.working, .waiting, .done, nil]
    overflow.titles = (0..<10).map { "terraform-apply-session-\($0)" }
    overflow.glyphs = (0..<10).map { glyphCycle[$0 % glyphCycle.count] }
    overflow.active = 6
    overflow.cwd = "~/work/infra/terraform/modules/network"
    overflow.rollup = [("working", 8), ("waiting", 2), ("idle", 15)]
    try writePNG(
      chromeBand(overflow, size: size), size: size, name: "statusrow_overflow.png", dir: dir)
  }

  /// EditorPane スナップショット。**本物の EditorPaneRoot＋見本同等 fixture を描く**
  /// （中身をスタブしない）。design 正典 ステージ（640×520）の scene 5 と同寸:
  /// ペイン幅 min(552, 58%×640)=371＋スプリッタ5、本体高 440（520 − TopBar26 − TabBar28 − 下段26）。
  private func renderEditorPaneSnapshots(dir: URL) throws {
    let size = NSSize(width: 376, height: 440)
    func write(_ model: EditorPaneModel, _ name: String) throws {
      // 実機ではウィンドウ地（bgBase＋glow）の上に translucent wash で載るため、地を敷いて撮る。
      try writePNG(
        EditorPaneRoot(model: model)
          .frame(width: size.width, height: size.height)
          .background(Color.theme.bgBase),
        size: size, name: name, dir: dir)
    }
    // 3ツール × 各状態（ツリー+全文 / md ソース / md プレビュー / git変更+diff / git履歴+CommitDetail
    // / ブラウザ静的モック）。
    try write(EditorPaneFixtures.treeModel(), "editorpane_tree.png")
    try write(EditorPaneFixtures.mdSourceModel(), "editorpane_md_source.png")
    try write(EditorPaneFixtures.mdPreviewModel(), "editorpane_md_preview.png")
    try write(EditorPaneFixtures.changesDiffModel(), "editorpane_changes.png")
    try write(EditorPaneFixtures.changesBannerModel(), "editorpane_changes_banner.png")
    try write(EditorPaneFixtures.historyModel(), "editorpane_history.png")
    try write(EditorPaneFixtures.browserModel(), "editorpane_browser.png")
    // 空状態（git 外）。
    let empty = EditorPaneModel()
    empty.empty = "git リポジトリではありません\n~/Downloads"
    try write(empty, "editorpane_empty.png")
    // 未コミット変更ゼロ → git レールがグレーアウト（ツリー本体は開いたまま）。
    let noChange = EditorPaneFixtures.treeModel()
    noChange.files = []
    try write(noChange, "editorpane_no_changes.png")
    // 本体を閉じた常駐レールのみ（32px・git ドット点灯・最下部 ⌘/）。
    let railClosed = EditorPaneFixtures.treeModel()
    railClosed.ui.paneOpen = false
    try writePNG(
      EditorPaneRoot(model: railClosed)
        .frame(width: 32, height: 440)
        .background(Color.theme.bgBase),
      size: NSSize(width: 32, height: 440), name: "editorpane_rail_closed.png", dir: dir)
  }

  /// 補完ドロップダウン（薄い行・複数 group・cap 超過でスクロール表現＝右つまみ＋下フェード）を端末地に重ねる。
  /// 候補が cap（~5 行）を超えるよう厚めに積み、選択を下方に送って scrollY>0 のスクロール追従
  /// （選択行が下端フェードの上に退避して保たれること）を見る。
  private func renderCompletionSnapshot(dir: URL) throws {
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
    completion.selected = 7
    try writePNG(
      completionSnapshot(completion), size: NSSize(width: 320, height: 300),
      name: "completion.png", dir: dir)

    // side card は CompletionList の外（AppKit 配置）なので単体で 1 枚撮る（ピクセル突合用）。
    try writePNG(
      CompletionSideCard(
        name: "feature/editor-pane", kind: .argument,
        description: "エディタペインの作業ブランチ。説明が複数行に渡るときも折り返して収める"
      )
      .padding(Theme.Space.phrase)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase),
      size: NSSize(width: 260, height: 200), name: "completion_sidecard.png", dir: dir)

    // design 正典 Autocomplete 同データ（候補パネル＋サイドカードの2枚組・突合用）。
    try writePNG(
      HStack(alignment: .top, spacing: Theme.Space.note) {
        CompletionList(model: DesignSceneFixtures.completionModel())
        DesignSceneFixtures.completionSideCard()
      }
      .padding(Theme.Space.phrase)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase),
      size: NSSize(width: 520, height: 240), name: "completion_design.png", dir: dir)
  }

  /// パレット各状態（AgentPalette 一覧/詳細・Workspace・少数行ハグ・多数行 cap）を撮る。
  private func renderPaletteSnapshots(dir: URL, cardSize: NSSize) throws {
    // AgentPalette（一覧 / 詳細メニュー）。
    let listModel = PaletteModel()
    listModel.hint = "↵ 起動   → 詳細   esc 閉じる"
    listModel.rows = [
      .init(label: "● claude", chevron: true),
      .init(label: "  codex", chevron: true),
      .init(label: "  agy", chevron: true),
    ]
    try writePNG(paletteSnapshot(listModel), size: cardSize, name: "palette_list.png", dir: dir)

    let submenuModel = PaletteModel()
    submenuModel.breadcrumb = "‹ claude"
    submenuModel.hint = "↵ 実行   ← 戻る   esc 閉じる"
    submenuModel.rows = [.init(label: "デフォルトに設定")]
    try writePNG(
      paletteSnapshot(submenuModel), size: cardSize, name: "palette_submenu.png", dir: dir)

    // WorkspacePalette 一覧（フィルタ欄＋WS切替行：名前＋インラインチップ＋パス）。
    let wsModel = PaletteModel()
    wsModel.fieldVisible = true
    wsModel.placeholder = "workspace を切替 / 入力で新規作成"
    wsModel.hint = "↵ 切替/作成   → 詳細   esc 閉じる"
    wsModel.rows = [
      wsRow("main", [("working", 2), ("waiting", 1)], "~/dev/main"),
      wsRow("infra", [("done", 3)], "~/work/infra"),
      wsRow("archive", [], "~/archive", dimmed: true),
    ]
    try writePNG(
      paletteSnapshot(wsModel), size: cardSize, name: "palette_workspace.png", dir: dir)

    // design 正典 WorkspaceSwitcher 同データ（ステージ 640×520・overlay ごと・突合用）。
    let stage = NSSize(width: 640, height: 520)
    try writePNG(
      ZStack {
        BackgroundGlow()
        PaletteOverlay(model: DesignSceneFixtures.workspaceModel())
      }.frame(width: stage.width, height: stage.height),
      size: stage, name: "palette_workspace_design.png", dir: dir)

    // 少数行（cap 未満）: 行リストが内容高でハグし、余白・スクロール余地が出ないことを見る（fieldVisible=false）。
    let hugModel = PaletteModel()
    hugModel.hint = "↵ 起動   → 詳細   esc 閉じる"
    hugModel.rows = [
      wsRow("claude", [("working", 2), ("waiting", 1)], "~/dev/claude"),
      wsRow("codex", [("done", 3)], "~/dev/codex"),
      wsRow("agy", [], "~/dev/agy"),
      wsRow("gemini（休眠）", [], "~/dev/gemini", dimmed: true),
    ]
    try writePNG(paletteSnapshot(hugModel), size: cardSize, name: "palette_hug_few.png", dir: dir)

    // 多数行（cap 超過）: 行リスト高が capHeight で頭打ち＋内部スクロール＋選択追従を見る。
    // field あり/なし両方。tall キャンバスでカード全体（field＋リスト＋hint）が収まることも確認する。
    let tall = NSSize(width: 500, height: 600)
    try writePNG(
      paletteSnapshot(manyRowPalette(fieldVisible: true)), size: tall,
      name: "palette_cap_field.png", dir: dir)
    try writePNG(
      paletteSnapshot(manyRowPalette(fieldVisible: false)), size: tall,
      name: "palette_cap_nofield.png", dir: dir)

    // 設定パレット（Cmd+,）root / テーマサブパレット。本物の SettingsPaletteModel が render へ
    // 立て下げた状態を Light/Dark で撮る（遷移過程は flow の settings_palette が担う）。
    // root は WS 上書きありで撮る＝「（この WS では …）」注記（muted 補足）が主値より弱く読めるか、
    // 選択行の tint 塗りの上でも読めるかを両 appearance で見る。
    let settingsRoot = settingsPaletteModel(overrideFontSize: 16, overrideTheme: .dark)
    try writePNG(
      paletteSnapshot(settingsRoot.render), size: NSSize(width: 500, height: 520),
      name: "palette_settings_root.png", dir: dir)

    let settingsTheme = settingsPaletteModel()
    settingsTheme.render.selected = 5  // テーマ行
    settingsTheme.render.onActivate()  // 潜る → Auto/Dark/Light の固定3択・● が実効値 Auto
    try writePNG(
      paletteSnapshot(settingsTheme.render), size: cardSize,
      name: "palette_settings_theme.png", dir: dir)
  }

  /// 設定パレット gallery 用の実モデル（flow の testSettingsPalette と同じ初期値）。
  private func settingsPaletteModel(
    overrideFontSize: Int? = nil, overrideTheme: ThemeMode? = nil
  ) -> SettingsPaletteModel {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 14
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    global[SettingKeys.defaultAgent] = "claude"
    global[SettingKeys.devFeaturesEnabled] = true
    var override = SettingsLayer()
    override[SettingKeys.fontSize] = overrideFontSize
    override[SettingKeys.theme] = overrideTheme
    return SettingsPaletteModel(
      values: ScopedSettingsValues(global: global, override: override),
      fontNames: ["Menlo", "Monaco", "SF Mono"],
      agents: ["claude", "codex", "agy"],
      localization: LocalizationStore(language: .ja))
  }

  /// cap 検証用の 18 行パレット（rollup 散らし・選択は下方で追従スクロールが要る位置）。
  private func manyRowPalette(fieldVisible: Bool) -> PaletteModel {
    let model = PaletteModel()
    model.fieldVisible = fieldVisible
    if fieldVisible {
      model.placeholder = "workspace を切替 / 入力で新規作成"
      model.hint = "↵ 切替/作成   → 詳細   esc 閉じる"
    } else {
      model.hint = "↵ 起動   → 詳細   esc 閉じる"
    }
    let rollups: [[(state: String, count: Int)]] = [
      [("working", 2), ("waiting", 1)], [("done", 4)], [], [("idle", 1)],
    ]
    model.rows = (0..<18).map { i in
      let name = "workspace-\(String(format: "%02d", i))"
      return wsRow(
        name, rollups[i % rollups.count], "~/dev/\(name)", dimmed: i % 7 == 6)
    }
    model.selected = 14  // 下方選択 → onAppear の scrollTo が cap 内へ追従するか
    return model
  }

  /// WS切替行の snapshot 用 fixture（customContent 経由で本物の `WorkspaceSwitcherRow` を描く）。
  private func wsRow(
    _ name: String, _ rollup: [(state: String, count: Int)], _ path: String,
    dimmed: Bool = false
  ) -> PaletteModel.RowItem {
    PaletteModel.RowItem(
      label: name, dimmed: dimmed,
      customContent: AnyView(WorkspaceSwitcherRow(name: name, rollup: rollup, path: path)))
  }

  /// dark は `name` のまま、light は `<base>_light.png` で書く（doc どおり両 appearance を出力）。
  func writePNG<V: View>(_ view: V, size: NSSize, name: String, dir: URL) throws {
    let base = (name as NSString).deletingPathExtension
    for dark in [true, false] {
      let data = try XCTUnwrap(renderPNG(view, size: size, dark: dark))
      let url = dir.appendingPathComponent(dark ? name : "\(base)_light.png")
      try data.write(to: url)
      print("[gallery] wrote \(url.path)")
    }
  }

  /// 出力先。既定は repo 内 `.preview/gallery`（gitignore 済・散らからない・コミットに混ざらない）。
  private func outputDir() -> URL {
    if let override = ProcessInfo.processInfo.environment["ORBE_GALLERY_DIR"] {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return previewDir("gallery")
  }
}

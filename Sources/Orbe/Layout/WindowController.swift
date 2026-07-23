import AppKit
import GhosttyKit
import SwiftUI

/// 1 ウィンドウを所有し、複数の workspace を束ねる。
/// workspace = 名前付きコンテナ（root path ＋ 複数タブ）。各タブは独立した分割ツリー
/// （TerminalController）。非アクティブ workspace の TerminalController はオブジェクトとして
/// 保持され続け、配下 surface は生きたまま（keep-alive）。
/// 構成はディスクに永続化し、起動時に復元する（WorkspacePersistence）。
final class WindowController: NSObject, NSWindowDelegate {
  let window: NSWindow
  // chrome（StatusRow）の状態。WindowController が所有して更新する（読みは同モジュールのテストも使う）。
  let statusModel: StatusRowModel
  // パレット提示の拡張（WindowController+Palette）も握るため internal。
  let model: AppShellModel
  /// SwiftUI ルート（`AppShell`）を載せる NSHostingView（overlay は `AppShell` の `.overlay` で compose）。
  private let hostingView: ChromeHostingView
  // ドメイン/セッション状態（workspaces/activeWorkspace）の所有者。配列の CRUD・index 演算は
  // すべてここへ委譲し、WindowController は NSView 副作用と chrome 投影のコーディネータに徹する。
  let store: SessionStore
  // chrome 各面（StatusRow・パレット・EditorPane）へ背景透過/ブラーを届ける観測可能ホルダー。
  // 値は syncWindowOpacity と同一 tick で更新し、各 NSHostingView root へ Environment 注入する。
  let chromeTranslucency = ChromeTranslucency()
  // エージェント状態面 3 箇所へ状態アイコン上書きを届ける観測可能ホルダー。値は applyActiveWorkspaceConfig が
  // 実効設定（agentStateIcons）から同一 tick で更新し、各 NSHostingView root へ Environment 注入する。
  let agentIconResolver = AgentIconResolver()
  // chrome 全域のフォント割り当て（絵文字 Noto/Apple・タブタイトルフォント）を届ける観測可能ホルダー。
  // 値は applyActiveWorkspaceConfig が実効設定から同一 tick で更新し、各 NSHostingView root へ注入する。
  let fontResolver = ChromeFontResolver()
  // 現在の UI 言語ホルダー。起動時に app-state の preferredLanguage（未設定は OS 追従）で解決し、
  // 各 NSHostingView root（AppShell・EditorPaneRoot）へ Environment 注入する。言語変更は初回言語画面と
  // 設定パレットの言語行が行い、@Observable 経由で全 chrome を一斉再描画する。
  let localization = LocalizationStore(
    language: Language(rawValue: AppStatePersistence.load()?.preferredLanguage ?? "")
      ?? .systemDefault)
  // 言語変更の通知（AppDelegate がメインメニューの再構築へ配線する）。
  var onLanguageChanged: (() -> Void)?
  // 保存系（WindowController+Persistence）が別ファイルから触るため internal。
  var pendingSave: DispatchWorkItem?
  // 設定パレットのドメインA連続変更（font-size ←→ 長押し等）の reloadConfig 畳み込み（WindowController+Palette）。
  var pendingConfigReload: DispatchWorkItem?
  // 記憶するウィンドウサイズ（ユーザーが選んだ意図サイズ。表示用クランプは含めない）。
  // 保存はこの値を書き、現フレームは書かない——小画面で起動した際のクランプ縮小値が
  // 記憶を上書きして大画面用サイズを消すのを防ぐ。
  var rememberedWindowSize: WindowSize?
  // 復元時の programmatic な setFrame を windowDidResize の取り込みから除外するフラグ。
  var isApplyingRestoredSize = false
  // chrome 更新の coalesce 状態。高頻度 report でも runloop tick 単位に 1 回へ間引く。
  private var chromeDirty = false
  private var chromeFlushScheduled = false
  private let editorPane: EditorPaneController
  // 設定の in-memory SSOT（global 層）。パレット・control・opacity 系・AgentLauncher の default 解決が読む。
  let settingsStore = SettingsStore()
  var devFeaturesEnabled = false  // 右バー gate。アクティブ WS 実効値から applyActiveWorkspaceConfig が派生。
  // パレット提示の拡張（WindowController+Palette）が設定パレットの defaultAgent 配線で触るため internal。
  let agentLauncher = AgentLauncher()
  // アップデート面。状態（UI 唯一の情報源）は updaterService が生成・所有し、提示配線は WindowController+Update。
  let updaterService = UpdaterService()

  // 読みは store へ転送する（制御チャネル・chrome・パレット・永続・テストが多数の箇所で読むため、
  // 従来の可視性（internal）を保って読み site を無改変にする）。所有と全ミューテーションは store。
  var workspaces: [Workspace] { store.workspaces }
  var activeWorkspace: Int { store.activeWorkspace }
  var current: Workspace { store.current }
  /// 前面 overlay の種別（テスト用の検査面）。
  var presentedOverlay: AppShellModel.Overlay { model.overlay }

  override init() {
    let frame = NSRect(x: 0, y: 0, width: 800, height: 500)
    window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    let statusModel = StatusRowModel()
    self.statusModel = statusModel
    let model = AppShellModel(statusModel: statusModel, content: NSView())
    self.model = model
    hostingView = ChromeHostingView(
      rootView: AppShell(
        model: model, translucency: chromeTranslucency, agentIconResolver: agentIconResolver,
        fontResolver: fontResolver, localization: localization))
    editorPane = EditorPaneController(
      translucency: chromeTranslucency, fontResolver: fontResolver, localization: localization)
    store = SessionStore()  // 実体の populate は super.init 後（wire に self が要る）
    super.init()

    // タイトルバーは表示しない。chrome（StatusRow）がその領域を占め、
    // 信号機ボタンだけがコンテンツ上に残る。
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isRestorable = false  // OS 標準復元を無効化し、自前 JSON 復元に一本化
    window.delegate = self
    window.contentView = hostingView
    syncWindowOpacity()  // 起動時に既定 95% の背景透過を適用（WindowController+Opacity）
    // 背景ブラーの初回適用は windowDidBecomeKey が担う（init は windowNumber 未確定で CGS が効かない）。
    // SwiftUI に content スロット（端末ツリーの器）を即マウントさせ、初回 select() の
    // makeFirstResponder が成立する（= 起動直後からアクティブペインがキー入力を受ける）状態を作る。
    hostingView.layoutSubtreeIfNeeded()
    wireChromeCallbacks()

    editorPane.onFocusTerminal = { [weak self] in self?.focusActivePane() }
    editorPane.pane.onToggle = { [weak self] in self?.toggleEditorPane() }
    editorPane.pane.onWidthChange = { [weak self] width in self?.model.sideWidth = width }
    editorPane.onDisplayStateChange = { [weak self] in self?.projectEditorDisplayState() }
    editorPane.onPersistChange = { [weak self] in self?.scheduleSave() }
    model.sidePanel = editorPane.pane  // 常駐 facade（可視は cwd 追従で決める）
    editorPane.start()  // dev サーバー検出のポーリングを起こす（ブラウザボタンのグレーアウト追従）

    if let file = WorkspacePersistence.load() {
      restore(from: file)  // activateCurrent 経由で applyActiveWorkspaceConfig（外観＋gui.conf）が走る
    } else {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      store.load(workspaces: [Workspace(name: "default", rootPath: home)], activeWorkspace: 0)
      newTab()
      // 初回起動（復元なし）も実効設定の反映集約点を通す。gui.conf の theme 定数行が初回から
      // 無いと、ユーザー ~/.config/ghostty の theme 指定が初回起動に限り勝ってしまう。
      applyActiveWorkspaceConfig()
    }
    agentLauncher.appModel = model
    agentLauncher.localization = localization  // 起動パレット・オンボーディングの文言引き用
    configureAgentDefaults()
    agentLauncher.onLaunch = { [weak self] agent, env in self?.openAgentTab(agent, env: env) }
    // 起動/オンボーディング overlay の畳み込みも、他 overlay と同じく teardown 後の次 tick で focus を再確定する。
    agentLauncher.onDismissPalette = { [weak self] in
      self?.focusActivePane()
      self?.reconfirmFocusNextTick()
    }
    showFirstRunFlow()  // 初回言語選択（preferredLanguage 未設定時）→ 既存 Onboarding（各 CLI へ導入）
    cleanupLegacyCompletionIfNeeded()  // 旧方式が zshrc へ書いた managed block を一度だけ除去
    wireUpdateUI()  // アップデート提示導線を配線し、ゲートを通れば update サイクル開始
    window.center()
  }

  /// chrome（StatusRow・SwiftUI ルート）からの操作コールバック配線。
  private func wireChromeCallbacks() {
    statusModel.onSelect = { [weak self] i in self?.select(i) }
    statusModel.onNewTab = { [weak self] in self?.newTab() }
    // pane 非依存 chrome コマンドの window レベル配信（surface が居ない0タブでも届く）。
    hostingView.onWindowCommand = { [weak self] command in
      self?.handleWindowKeyCommand(command) ?? false
    }
    statusModel.onReorder = { [weak self] from, to in
      guard let self, self.store.moveTab(from: from, to: to) else { return }
      // 並び替えで titles 順が変わると editingIndex（位置 index）が別タブを指す（count 不変で
      // StatusRowView 側の onChange も検知不能）。編集中なら畳む。
      if self.statusModel.editingIndex != nil { self.endTabRename() }
      self.refreshChrome()  // current.tabs 順を再投影（表示追従）
      self.scheduleSave()  // 新順を workspaces.json へ（1 秒デバウンス）
    }
  }

  /// AgentLauncher の default agent 配線（読み＝アクティブ WS の実効値・書込＝global スコープの設定変更）。
  private func configureAgentDefaults() {
    agentLauncher.configuredDefault = { [weak self] in
      self?.activeEffectiveSettings()[SettingKeys.defaultAgent]
    }
    agentLauncher.onSetDefault = { [weak self] command in
      self?.applySetting(SettingChange(SettingKeys.defaultAgent, command), scope: .global)
    }
  }

  // MARK: - タブ（アクティブ workspace 内）

  /// タブ（TerminalController）に上位への通知クロージャを配線する。生成は呼び出し側。
  /// 制御チャネル（WindowController+Control）も使うため internal。
  func wire(_ tc: TerminalController) -> TerminalController {
    tc.onEmpty = { [weak self, weak tc] in self?.closeTab(tc) }
    tc.onActiveTitleChange = { [weak self] in self?.refreshChrome() }
    tc.onLayoutChange = { [weak self] in self?.scheduleSave() }
    tc.onPwdChange = { [weak self] in self?.paneDidReportPwd() }
    tc.onAgentStateChange = { [weak self] in
      self?.consumeActiveTabDoneIfFocused()
      self?.refreshChrome()
    }
    tc.onWindowCommand = { [weak self] command in self?.handleWindowCommand(command) }
    return tc
  }

  func newTab() {
    store.appendTabToActive(wire(TerminalController(initialCwd: store.newSurfaceCwd())))
    select(current.tabs.count - 1)
    scheduleSave()
  }

  func nextTab() {
    guard let i = store.nextTabIndex() else { return }
    select(i)
  }
  func prevTab() {
    guard let i = store.prevTabIndex() else { return }
    select(i)
  }

  /// 不変条件: model.content はアクティブ workspace の全タブの rootContainer を保持し、アクティブ
  /// のみ可視・他は isHidden（他 WS のビューは外す。surface は keep-alive）。可視タブは即時 mount し、
  /// 未 mount の隠れタブは後続 tick へ分割 mount（surface 誕生を 1 turn で N 個積まない）。全タブは
  /// 最終的に mount され viewDidMoveToWindow で surface が誕生。制御チャネルも使うため internal。
  func select(_ index: Int) {
    guard store.recordSelection(index) else { return }
    // 別タブへ切替＝インライン改名の文脈が崩れる。編集中なら畳む（dragFrom と同じ「集合/選択が
    // 変わったら継続は不正」不変条件。blur 自己修復に頼らず SSOT 遷移点で決定的に解除する）。
    if statusModel.editingIndex != nil { endTabRename() }
    model.contentIsEmpty = false  // タブが載る＝surface が地を塗るので 0タブ backstop を下げる（二重 veil 回避）
    let ws = current
    // アクティブ WS に属さないビュー（前 WS のタブ）を外す。surface は keep-alive で生存。
    let wanted = ws.tabs.map { ObjectIdentifier($0.rootContainer) }
    for sub in model.content.subviews where !wanted.contains(ObjectIdentifier(sub)) {
      sub.removeFromSuperview()
    }
    // 可視タブを同期 mount（即操作可能に＝この turn の surface 誕生を 1 枚へ上限化）。既 mount の
    // 隠れタブは isHidden/frame を即時更新（既に surface 在りで安価）。未 mount の隠れタブの
    // surface 誕生は後続 tick へ分割し、1 turn で N 個まとめて生成して固まるのを防ぐ。
    for (i, tc) in ws.tabs.enumerated()
    where i == index || tc.rootContainer.superview === model.content {
      mountTab(tc, visible: i == index)
    }
    // overlay 表示中は入力を奪わない（フォーカス復帰は dismiss 側が担う）。
    if model.overlay == .none { focusActivePane() }
    consumeActiveTabDoneIfFocused()
    refreshChrome()
    scheduleHiddenMounts(for: ws)
  }

  /// タブ 1 枚を model.content へ mount（surface 誕生は viewDidMoveToWindow 経由で冪等に 1 度）。
  /// 隠れタブも実サイズで起こす（pty winsize 正常）。frame/isHidden は既 mount でも毎回更新。
  private func mountTab(_ tc: TerminalController, visible: Bool) {
    if tc.rootContainer.superview !== model.content {
      tc.rootContainer.autoresizingMask = [.width, .height]
      model.content.addSubview(tc.rootContainer)
    }
    tc.rootContainer.frame = model.content.bounds
    tc.rootContainer.isHidden = !visible
  }

  /// 未 mount の隠れタブを後続 runloop tick で 1 枚ずつ mount（surface 誕生を分割）。
  /// 全タブ最終 mount・resume 起動を保つ。フラッシュ時に対象 WS がまだアクティブか
  /// 確認し、切替済みなら破棄して孤児 addSubview を防ぐ（次のアクティブ化でまた mount 対象＝冪等）。
  private func scheduleHiddenMounts(for ws: Workspace) {
    guard ws.tabs.contains(where: { $0.rootContainer.superview !== model.content }) else { return }
    DispatchQueue.main.async { [weak self, weak ws] in
      guard let self, let ws, self.current === ws else { return }
      guard let tc = ws.tabs.first(where: { $0.rootContainer.superview !== self.model.content })
      else { return }
      self.mountTab(tc, visible: false)  // 隠れタブ＝不可視（surface 誕生・resume は走る）
      self.scheduleHiddenMounts(for: ws)
    }
  }

  /// 完了通知の消費：ウィンドウがキー（前面）の時だけ、アクティブ表示タブの
  /// 全 done ペインを消費して集約 done バッジを消す。背面・背景タブの done は残す。
  /// 3 トリガ（タブ活性化・done 到着・前面復帰）が共有する。
  private func consumeActiveTabDoneIfFocused() {
    guard window.isKeyWindow, current.tabs.indices.contains(current.active) else { return }
    current.tabs[current.active].consumeDoneState()
  }

  /// タブを閉じる。発火源はユーザー操作（Cmd+W）に限らず、shell の exit
  /// （close_surface_cb → onEmpty）が背景タブ・背景 workspace からも届くため、
  /// アクティブ文脈を前提にせず所属 workspace を特定して処理する。
  /// 制御 API（`close_tab`）も id 解決の上でここへ委譲する（WindowController+Control）ため internal。
  func closeTab(_ tc: TerminalController?) {
    guard let tc else { return }
    // タブ集合が変わると editingIndex（位置 index）が別タブを指しうる。編集中なら畳む
    // （前方の背景タブが shell exit する等、フォーカスを保ったまま集合が変わる経路を決定的に解除）。
    if statusModel.editingIndex != nil { endTabRename() }
    switch store.removeTab(tc) {
    case .notFound:
      return
    case .emptiedActive:
      // アクティブ workspace が0タブ化。閉じたタブの rootContainer を content から外し空表示にする
      // （従来 select が担う唯一のビュー除去経路をここで明示し surface leak を避ける）。
      clearActiveContent()
    case .reselectActive(let i):
      // 閉じたタブの rootContainer を model.content から外す唯一の経路が select() の不要ビュー除去なので、
      // 背景タブの close も必ず通す（通さないと外れた TerminalController を retain し続け surface がリークする）。
      select(i)
    case .backgroundChanged:
      refreshChrome()  // 背景タブ/背景 workspace の空化でも chrome 横断 rollup を同期する
    }
    reloadPalette()  // パレット表示中の外因変異（shell exit でのタブ消滅・0タブ化）でも表示を実状態へ追従させる
    scheduleSave()
  }

  /// chrome 更新を要求する。`window.title`（Mission Control 用・O(1)）は即時反映し、重い StatusRow
  /// snapshot（全 workspace×全タブ×全ペイン走査）は dirty を立て runloop tick 末尾に 1 回だけ予約。
  /// 同一 turn 内の N 回の要求（高頻度 report_agent 等）は 1 回の `flushChrome` に畳む。
  func refreshChrome() {
    window.title = current.name
    chromeDirty = true
    guard !chromeFlushScheduled else { return }
    chromeFlushScheduled = true
    DispatchQueue.main.async { [weak self] in self?.flushChrome() }
  }

  /// coalesce した StatusRow 更新を現アクティブ workspace の**最新**状態へ実反映しエディタペインも追従
  /// （取りこぼしゼロ＝中間状態のみ落ち最終状態は必ず反映）。同期反映が要る経路（テスト）は直接呼ぶ。
  func flushChrome() {
    chromeFlushScheduled = false
    guard chromeDirty else { return }
    chromeDirty = false
    statusModel.update(
      StatusRowModel.Snapshot(
        workspace: current.name,
        titles: current.tabs.map { $0.displayTitle(workspaceRoot: current.rootPath) },
        glyphs: current.tabs.map { $0.aggregateAgentState() },
        active: current.active,
        cwd: store.activePaneCwd(),
        rollup: AgentRollup.ordered(AgentRollup.grandTotal(of: workspaces))))
    editorPane.retarget(cwd: store.activePaneCwd(), ui: store.activeEditorUI())
  }

  // MARK: - エディタペイン

  /// `Cmd+/`。アクティブタブの本体パネルの開閉トグル（レールは常駐なので隠さない）。
  /// repo 未解決（非 git）なら no-op。閉じたらターミナルへフォーカスを返す（controller が担う）。
  func toggleEditorPane() {
    editorPane.togglePaneOpen()
  }

  /// EditorPane の facade 可視（repo 解決）・本体開閉を AppShell へ投影する（幅・表示の駆動）。
  /// 開発中の機能トグルが off の間は facade を常に隠す——gate をこの投影集約点 1 本に閉じ、
  /// Cmd+G/Cmd+/（toggleEditorPane）等どの経路で editorPane が開いても右バーは AppShell に描画されない。
  func projectEditorDisplayState() {
    model.sideFacadeVisible = devFeaturesEnabled && editorPane.facadeVisible
    model.sidePaneOpen = editorPane.paneOpen
  }

  /// Cmd+Shift+↑/↓。ToolRail のツールを上下に切替（端でさらに進むと本体を閉じる）。
  /// 非表示・空状態（ToolRail 非描画）のときは no-op。
  func navigateEditorTool(_ delta: Int) {
    guard editorPane.facadeVisible, editorPane.model.empty == nil else { return }
    editorPane.model.selectAdjacentTool(delta)
  }

  /// アクティブタブの preferredFocusPane へフォーカスを戻す（パレットの dismiss と同じ規則）。
  func focusActivePane() {
    guard current.tabs.indices.contains(current.active) else { return }
    window.makeFirstResponder(current.tabs[current.active].preferredFocusPane)
  }

  /// OSC 7 の cwd 報告を受けた。行の cwd 表示を更新し、永続保存を予約する。
  private func paneDidReportPwd() {
    refreshChrome()
    scheduleSave()
  }

  // MARK: - エージェント起動（検出・パレット・デフォルト解決は AgentLauncher）

  /// 指定 cwd（既定はアクティブペインの cwd、0タブは workspace の rootPath）の新タブで、
  /// エージェントをシェルの代わりに直接起動する。Dispatch は解決した worktree パスを cwd に渡す。
  /// 終了はシェル exit と同じ経路（close_surface_cb → onEmpty）でタブが閉じる。
  func openAgentTab(_ agent: AgentCLI, env: [String: String] = [:], cwd: String? = nil) {
    let tc = TerminalController(
      initialCwd: cwd ?? store.newSurfaceCwd(), initialCommand: agent.path, initialEnv: env)
    store.appendTabToActive(wire(tc))
    select(current.tabs.count - 1)
    scheduleSave()
  }

  // MARK: - 復元（保存系は WindowController+Persistence）

  private func restore(from file: WorkspacesFile) {
    restoreWindowSize(file.windowSize)
    let resume: TerminalController.ResumeSpawn = { [agentLauncher] in
      agentLauncher.resumeSpawn(for: $0)
    }
    var restored: [Workspace] = []
    for state in file.workspaces {
      let ws = Workspace(name: state.name, rootPath: state.rootPath)
      ws.lastUsedAt = state.lastUsedAt  // MRU 並べ替えキーを読み戻す（旧データは nil）
      ws.settingsOverride = state.settingsOverride  // 設定上書きを読み戻す（旧データは nil＝global 継承）
      for tab in state.tabs {
        let tc = TerminalController(restoring: tab.tree, resumeSpawn: resume)
        tc.explicitTitle = tab.explicitTitle
        tc.editorUI.paneOpen = tab.editor.open
        tc.editorUI.tool = EditorTool(persistKey: tab.editor.tool)
        ws.tabs.append(wire(tc))
      }
      // 0タブ（休眠）workspace はそのまま残す。アクティブ化（切替・下の activateCurrent）は空表示
      // で、シェルは自動起動しない。背景の休眠 workspace も空のまま keep する。
      ws.active = ws.tabs.isEmpty ? 0 : min(max(0, state.activeTab), ws.tabs.count - 1)
      restored.append(ws)
    }
    // workspaces 非空は load() が保証する（空 workspaces のファイルは load が nil を返す）。
    store.load(
      workspaces: restored,
      activeWorkspace: min(max(0, file.activeWorkspace), restored.count - 1))
    activateCurrent()  // 復元アクティブが0タブ（休眠保存）なら空表示（シェルは起こさない）
  }

  // アプリ前面復帰：背面で届いていたアクティブ表示タブの done を消費する。
  func windowDidBecomeKey(_ notification: Notification) {
    consumeActiveTabDoneIfFocused()
    refreshChrome()
    syncWindowBlur()  // 可視後の初回適用（起動時 init は windowNumber 未確定で CGS ブラーが効かない）
  }

}

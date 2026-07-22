import AppKit

/// エージェント起動の一式（検出カタログ・起動パレット・デフォルト設定）を束ねる。
/// WindowController からは「起動依頼をどう叶えるか」だけを受け取り、overlay の提示は注入された
/// `AppShellModel` の overlay 状態を立て下げて行う（エディタペインの EditorPaneController と同じ関心分離）。
final class AgentLauncher {
  /// SwiftUI ルートの overlay 状態（提示先）。WindowController が注入する。
  weak var appModel: AppShellModel?
  /// 現在言語ホルダー（起動パレット・オンボーディングの文言引き）。WindowController が所有ストアを注入する。
  var localization = LocalizationStore(language: .systemDefault)
  /// 新タブでの起動依頼（エージェントと、引き継ぐ追加環境変数）。
  var onLaunch: ((AgentCLI, [String: String]) -> Void)?
  /// パレット/オンボーディングを閉じた通知（フォーカス返却用）。
  var onDismissPalette: (() -> Void)?
  /// アクティブ WS の実効 default agent（生値・未設定/未検出もあり得る）を返す provider。WindowController が注入。
  /// 実際に起動される default は resolvedDefaultCommand（検出結果へ解決）。
  var configuredDefault: (() -> String?)?
  /// default agent を global スコープの設定変更として書く窓口。WindowController が注入（store 経由に一本化）。
  var onSetDefault: ((String) -> Void)?

  private let catalog = AgentCatalog()
  private var installProc: Process?  // 導入中の install.sh を寿命つなぎで保持

  init() {
    catalog.onChange = { [weak self] in self?.reloadPalette() }
    catalog.onResolved = { [weak self] in self?.handleResolved() }
    catalog.refresh()  // アプリ起動時の 1 回
  }

  /// Cmd+Shift+C。デフォルトエージェントを起動（検出ゼロならパレットの空状態を見せる）。
  func launchDefault() {
    guard let agent = resolvedDefault() else {
      showPalette()
      return
    }
    launch(agent)
  }

  /// Cmd+Shift+A。エージェント起動パレットを開く（既に開いていれば再フォーカス）。
  /// 開くたびに裏で再検出し、届いたら表示へ反映する（refresh は in-flight ガード付き）。
  func showPalette() {
    catalog.refresh()
    guard let appModel else { return }
    if appModel.overlay == .agentPalette {
      appModel.agentPalette?.focus()
      return
    }
    let p = AgentPaletteModel(localization: localization)
    p.onLaunch = { [weak self] agent in
      self?.dismissPalette()
      self?.launch(agent)
    }
    p.onSetDefault = { [weak self] agent in
      self?.setDefault(agent.command)
      self?.reloadPalette()
    }
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    // 初回検出 in-flight 中なら検出中を見せる（onResolved で立て下げて差し替え）。
    p.detecting = !catalog.hasResolved
    appModel.agentPalette = p
    appModel.overlay = .agentPalette
    reloadPalette()
    p.focus()
  }

  /// デフォルトエージェント（Cmd+Shift+C の起動対象）を global スコープへ設定する。設定 store 経由の
  /// 書込に一本化する（起動パレット Cmd+Shift+A・オンボーディングが呼ぶ。これらは WS 文脈を持たない）。
  func setDefault(_ command: String) { onSetDefault?(command) }

  /// 設定パレット用の検出済み（インストール済み）agent コマンド一覧。起動パレット（Cmd+Shift+A）と
  /// 同じ検出結果を共有し、未導入 agent を default に選べないようにする（表示と実起動の乖離を断つ）。
  var detectedCommands: [String] { catalog.agents.map(\.command) }

  /// 検出済み agent（command＋解決済み絶対 path）一覧。制御 API `list_agents` が
  /// アプリの canonical な検出結果をそのまま露出する窓口（新規 AgentCatalog を起こさない）。
  /// 検出未完了なら空配列。
  var detectedAgents: [AgentCLI] { catalog.agents }

  /// エージェントタブへ引き継ぐ環境（検出に使ったログインシェルの PATH）。launch と同じ解決を保証する。
  var launchEnvironment: [String: String] { catalog.shellPATH.map { ["PATH": $0] } ?? [:] }

  /// デフォルト解決の規則（SSOT）: 設定値が検出済みならそれ、無ければ検出順（claude>codex>agy）の先頭。
  /// 実起動（launchDefault）・起動パレットの ●・設定パレットの ●/ハイライトが同じこの 1 規則を読む
  /// （「現在のデフォルト」のキーを 1 つに保つ）。
  static func resolveDefault(configured: String?, detected: [String]) -> String? {
    detected.first(where: { $0 == configured }) ?? detected.first
  }

  /// 解決済みデフォルトの command。実際に起動される agent を指す公開窓口（設定パレット・dispatch が読む）。
  var resolvedDefaultCommand: String? {
    Self.resolveDefault(configured: configuredDefault?(), detected: detectedCommands)
  }

  /// 解決済みデフォルト（実際に Cmd+Shift+C で起動される agent）。
  private func resolvedDefault() -> AgentCLI? {
    catalog.agents.first { $0.command == resolvedDefaultCommand }
  }

  /// 環境にはログインシェルの PATH を渡す（エージェントの子プロセスにも検出時と同じ解決を保証）。
  private func launch(_ agent: AgentCLI) {
    onLaunch?(agent, catalog.shellPATH.map { ["PATH": $0] } ?? [:])
  }

  /// 初回起動オンボーディングを出す。検出 CLI を見せてデフォルトを選ばせ、状態追跡
  /// プラグインを per-CLI 進捗付きで導入する。`.app` 同梱が無い（`swift run` 等）か
  /// 導入済み（フラグ）なら何もしない。
  func showOnboardingIfNeeded() {
    guard let appModel,
      AppStatePersistence.load()?.agentPluginsInstalled != true,
      AgentPluginInstaller.bundledPluginDir != nil
    else { return }
    catalog.refresh()
    let m = OnboardingModel()
    m.detecting = !catalog.hasResolved
    m.setCommands(catalog.agents.map(\.command))
    m.onBegin = { [weak self] in self?.beginOnboardingInstall() }
    appModel.onboarding = m
    appModel.overlay = .onboarding
    m.focus()
  }

  /// 「始める」押下。選択中のデフォルトを保存し、導入を per-CLI 進捗で走らせる。
  /// 検出ゼロ（agent==nil）＝導入を 1 件も走らせていないので、導入済みフラグは立てずに閉じる
  /// （次回起動で再検出・再提示＝CLI を入れてからのリトライ余地を残す）。
  private func beginOnboardingInstall() {
    guard let model = appModel?.onboarding else { return }
    let agent =
      catalog.agents.indices.contains(model.selected) ? catalog.agents[model.selected] : nil
    guard let agent else {
      dismissOnboarding()
      return
    }
    // ephemeral バンドルではなく ORBE_STATE_DIR 非依存の安定パスへ実体化し、それを登録する。
    guard let stableDir = AgentPluginInstaller.materializeStablePlugin() else {
      dismissOnboarding()
      return
    }
    setDefault(agent.command)  // 書込は global スコープの設定変更として store 経由に一本化
    model.beginInstalling()
    installProc = AgentPluginInstaller.run(
      pluginDir: stableDir, shellPATH: catalog.ensureShellPATH(),
      onEvent: { [weak self] event in
        switch event {
        case .start(let cli): self?.appModel?.onboarding?.setStatus(cli, .installing)
        case .done(let cli, let ok):
          self?.appModel?.onboarding?.setStatus(cli, ok ? .done : .failed)
        case .skip(let cli): self?.appModel?.onboarding?.setStatus(cli, .skipped)
        }
      },
      onComplete: { [weak self] in self?.completeOnboarding() })
  }

  /// 導入完了。失敗 CLI が無ければフラグを立て（再導入防止）、進捗を見せてから閉じる。
  /// 失敗があればフラグを立てず、次回起動で再表示＝自動リトライさせる（install.sh は冪等）。
  private func completeOnboarding() {
    if appModel?.onboarding?.hasFailures != true {
      AppStatePersistence.update { $0.agentPluginsInstalled = true }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.dismissOnboarding()
    }
  }

  private func dismissOnboarding() {
    installProc = nil
    // 遅延 dismiss（completeOnboarding の 1 秒後）の間に別 overlay へ置換されていたら、
    // 自分のモデルだけ片付けて表示・フォーカスは触らない（単一 overlay enum の越境クローズを防ぐ）。
    let owned = appModel?.overlay == .onboarding
    appModel?.onboarding = nil
    guard owned else { return }
    appModel?.overlay = .none
    onDismissPalette?()
  }

  /// 永続から復元した agent セッションを resume 起動の (command, env) に解決する。
  /// 起動と同じくログインシェルの PATH を渡す。未対応 agent は nil（呼び出し側は素のシェルで復元）。
  func resumeSpawn(for session: AgentSession) -> (command: String, env: [String: String])? {
    guard
      let command = AgentCatalog.resumeCommand(
        forAgent: session.command, sessionId: session.sessionId)
    else { return nil }
    return (command, catalog.ensureShellPATH().map { ["PATH": $0] } ?? [:])
  }

  /// 検出完了の単一窓口。提示中の onboarding／palette 双方の detecting を解いて結果へ差し替える。
  private func handleResolved() {
    if let m = appModel?.onboarding {
      m.setCommands(catalog.agents.map(\.command))
      m.detecting = false
    }
    if let p = appModel?.agentPalette {
      p.detecting = false
      reloadPalette()
    }
  }

  private func reloadPalette() {
    appModel?.agentPalette?.setAgents(catalog.agents, defaultCommand: resolvedDefaultCommand)
  }

  private func dismissPalette() {
    appModel?.overlay = .none
    appModel?.agentPalette = nil
    onDismissPalette?()
  }
}

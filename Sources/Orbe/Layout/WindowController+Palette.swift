import AppKit

/// 前面 overlay（workspace コマンドパレット・タブリネーム）の提示と畳み込み。
/// WindowController 本体から overlay 提示の関心を分離する。
extension WindowController {
  /// overlay 遷移直後（提示・差し替え・畳み込み）に呼ぶ focus 再確定。去りゆくカードの TextField
  /// （field editor）teardown は次 runloop tick に走り、同期で当てた focus（新 overlay の入力欄 or 端末）を
  /// 奪い返す。その次 tick で「その時点の overlay の focus 対象」へ再確定して teardown に勝つ。
  /// overlay→overlay（作成フォーム↔切替パレット等）・overlay→端末（dismiss）の両方に効く一般形。
  func reconfirmFocusNextTick() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.model.overlay == .none {
        self.focusActivePane()
      } else {
        self.model.focusCurrentOverlayField()
      }
    }
  }

  /// 起動時の初回フロー。preferredLanguage 未設定なら言語選択を Onboarding の前段に出し、確定後に
  /// 既存 Onboarding へ進む。言語ゲートは Onboarding ゲート（agentPluginsInstalled ＋ 同梱プラグイン有無）とは独立。
  func showFirstRunFlow() {
    if AppStatePersistence.load()?.preferredLanguage == nil {
      showLanguageSelect { [weak self] in self?.agentLauncher.showOnboardingIfNeeded() }
    } else {
      agentLauncher.showOnboardingIfNeeded()  // 初回のみ・オンボーディングで各 CLI へ導入
    }
  }

  /// 初回起動の言語選択を出す（Onboarding の前段）。確定で「言語永続＋ストア更新＋メインメニュー再構築」を
  /// 束ね、overlay を下げてから `continuation`（既存 Onboarding へ進む）を呼ぶ。真のモーダル（scrim で閉じない）。
  func showLanguageSelect(then continuation: @escaping () -> Void) {
    let m = LanguageSelectModel(current: localization.language)
    m.onConfirm = { [weak self] language in
      guard let self else { return }
      self.localization.language = language  // @Observable が全 chrome を再描画
      AppStatePersistence.update { $0.preferredLanguage = language.rawValue }  // 確定を永続化
      self.onLanguageChanged?()  // AppKit メインメニューを新言語で再構築
      self.model.languageSelect = nil
      self.model.overlay = .none
      continuation()
    }
    model.languageSelect = m
    model.overlay = .languageSelect
    m.focus()
    reconfirmFocusNextTick()
  }

  /// Cmd+Shift+S。workspace コマンドパレットを開く（既に開いていれば入力欄へ再フォーカス）。
  func showWorkspacePalette() {
    if model.overlay == .workspacePalette {
      model.workspacePalette?.focus()
      return
    }
    let p = WorkspacePaletteModel(localization: localization)
    p.onSwitch = { [weak self] i in
      self?.switchWorkspace(to: i)
      self?.dismissPalette()
    }
    p.onCreate = { [weak self] name in
      self?.createWorkspace(name: name)
      self?.dismissPalette()
    }
    p.onCreateFlow = { [weak self] in
      self?.dismissPalette()
      self?.showWorkspaceCreate()
    }
    p.onRename = { [weak self] i, name in
      self?.renameWorkspace(i, to: name)
      self?.reloadPalette()
    }
    p.onSetDir = { [weak self] i, dir in
      self?.setWorkspaceDir(i, to: dir)
      self?.reloadPalette()
    }
    p.onClose = { [weak self] i in self?.closeWorkspace(i) }
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    model.workspacePalette = p
    model.overlay = .workspacePalette
    reloadPalette()
    p.selectActiveRow()  // 開いた直後の選択カーソルをアクティブ workspace 行へ載せる
    p.focus()
    reconfirmFocusNextTick()  // 去りゆくカード（作成フォーム等）の teardown に focus を奪われないよう次 tick で再確定
  }

  /// Cmd+N / 切替パレット末尾の「＋ 新規ワークスペース」。ソース切替（既存フォルダ / git clone）で workspace を
  /// 作る専用フォーム。既に開いていれば入力欄へ再フォーカス。dismiss は切替画面（⌘⇧S パレット）へ戻す。
  func showWorkspaceCreate() {
    if model.overlay == .workspaceCreate {
      model.workspaceCreate?.focus()
      return
    }
    // パス初期値＝アクティブペインの cwd（`~` 短縮）、無ければ `~`。clone 先の親も同じ初期値（model init）。
    let initialPath =
      store.activePaneCwd().map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~"
    let m = WorkspaceCreateModel(path: initialPath)
    m.onCreate = { [weak self] path, name in
      guard let self else { return }
      self.createWorkspace(name: name, rootPath: path)
      self.dismissPalette()  // 新タブ surface への focus 再確定（次 runloop tick）は dismissPalette が担う
    }
    // clone の git 知識は Git 層へ閉じる（Layout に git 引数を漏らさない＝addWorktree/prepareDirectory と同じ関心分離）。
    m.onClone = { url, dest, done in GitRepo.clone(url: url, dest: dest, completion: done) }
    m.onDismiss = { [weak self] in self?.showWorkspacePalette() }  // ＝切替画面へ戻す
    model.workspaceCreate = m
    model.overlay = .workspaceCreate
    m.focus()
    reconfirmFocusNextTick()  // 切替パレット→作成フォーム等の遷移で去りゆくカードの teardown に勝つ
  }

  /// Cmd+Shift+X。Dispatch パレット（worktree/branch/issue/PR から起動）を開く。
  /// git（即時）→gh（追従）のプログレッシブ表示・フィルタ・⇥ 起動先切替（agent/shell）・Enter 実行
  /// （worktree 解決＋新タブ起動）・⌘↵ でブラウザ表示までを配線する。
  func showDispatchPalette() {
    if model.overlay == .dispatchPalette {
      model.dispatchPalette?.focus()
      return
    }
    let p = DispatchPaletteModel()
    p.setTargets(
      agents: agentLauncher.detectedAgents,
      defaultCommand: agentLauncher.resolvedDefaultCommand)
    p.onDismiss = { [weak self] in self?.dismissPalette() }

    let cwd = store.activePaneCwd() ?? FileManager.default.homeDirectoryForCurrentUser.path
    // global 層に現 WS の上書きを重ねた実効テンプレートを注入する（二層が worktree 作成先に効く）。
    let effectiveSettings = EffectiveSettings(
      settingsStore.global.overlaid(with: current.settingsOverride ?? SettingsLayer()))
    let provider = DispatchDataProvider(
      cwd: cwd, model: p, localization: localization,
      worktreePathTemplate: effectiveSettings[SettingKeys.worktreePath])

    // クロージャは兄弟パレット同様 [weak self] のみとし、p/provider は self.model 経由で辿る
    // （p が onExecute を保持するため、p を強参照すると開くたびに自己循環でリークする）。
    p.onExecute = { [weak self] item in
      guard let self, let p = self.model.dispatchPalette,
        let provider = self.model.dispatchProvider, let action = item.action
      else { return }
      // 作成中の再入を弾く（Enter 連打で git worktree add が二重に走るのを防ぐ）。
      guard !p.isPreparing else { return }
      // targets は常に非空（shell が常在）のため実質常に成立。非同期 completion で使うため値で capture する。
      guard let target = p.selectedTarget else { return }
      p.errorMessage = nil
      p.isPreparing = true  // 進捗表示 ON。非同期 worktree 作成の待機中だけフッターにスピナが出る。
      provider.prepareDirectory(for: action) { [weak self] resolution in
        guard let self, let p = self.model.dispatchPalette else { return }
        switch resolution {
        case .ready(let dir):
          // 同期 .ready（既存 worktree 等）では true→dismiss が 1 tick で走り palette が破棄され無描画。
          p.isPreparing = false
          self.dismissPalette()
          switch target {
          case .agent(let agent):
            self.openAgentTab(agent, env: self.agentLauncher.launchEnvironment, cwd: dir)
          case .shell:
            self.openShellTab(cwd: dir)
          }
          // DispatchOverlay（focus を握る TextField 入り）の SwiftUI teardown は非同期で、
          // openAgentTab の同期フォーカス確定の後に first responder を奪いうる。teardown 後の
          // 次 runloop tick で新タブ surface へフォーカスを再確定し、即打鍵できる状態にする。
          DispatchQueue.main.async { [weak self] in self?.focusActivePane() }
        case .failed(let message):
          p.isPreparing = false  // 進捗表示 OFF。エラー表示にスピナが被らないよう必ず下ろす。
          p.errorMessage = message
        }
      }
    }
    p.onOpenWeb = { [weak self] item in
      guard let self, let provider = self.model.dispatchProvider else { return }
      provider.openWeb(for: item)
    }

    model.dispatchPalette = p
    model.dispatchProvider = provider
    model.overlay = .dispatchPalette
    provider.load()
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
  }

  /// Dispatch の shell 選択で、解決した worktree dir に素シェル（agent を走らせない）の新タブを開く。
  /// initialCommand を渡さない＝ Cmd+T/newTab と同じ既定シェル起動（`openAgentTab` と対をなす）。
  func openShellTab(cwd: String) {
    store.appendTabToActive(wire(TerminalController(initialCwd: cwd)))
    select(current.tabs.count - 1)
    scheduleSave()
  }

  func reloadPalette() {
    let items = workspaces.enumerated().map { entry -> WorkspacePaletteModel.Item in
      let ws = entry.element
      let dormant = !ws.activated
      // 未起動行は agentState rollup が元々 0 件のため、永続 leaf の総数を通常 idle 色チップに
      // 一本化する（0 件は出さない）。起動済み行は 0 件除外の rollup（存在する状態だけチップを出す）。
      let rollup: [(state: String, count: Int)]
      if dormant {
        let n = ws.dormantAgentCount()
        rollup = n > 0 ? [(state: "idle", count: n)] : []
      } else {
        rollup = AgentRollup.ordered(ws.agentCounts())
      }
      return WorkspacePaletteModel.Item(
        index: entry.offset, name: ws.name, isActive: entry.offset == activeWorkspace,
        dormant: dormant, agentRollup: rollup, dir: ws.rootPath)
    }
    // 起源 workspace（配列先頭 offset 0＝起動時の default WS）を MRU より優先して常に最上位へ固定する
    // （改名しても最上位。第一キー）。残りは最近使った順（MRU）: lastUsedAt 降順、同時刻・未設定
    // （旧データは全 nil）は元 offset 昇順で安定化し作成順を保つ（sorted は安定保証なしのため offset を
    // タイブレークに使う）。休眠（dormant）は位置のまま行ごと減光する別軸信号——末尾固定はしない。
    let order = workspaces.enumerated().sorted { a, b in
      if (a.offset == 0) != (b.offset == 0) { return a.offset == 0 }  // 起源を最上位に固定
      let ta = a.element.lastUsedAt ?? .distantPast
      let tb = b.element.lastUsedAt ?? .distantPast
      if ta != tb { return ta > tb }
      return a.offset < b.offset
    }
    model.workspacePalette?.setItems(order.map { items[$0.offset] })
    // パレット内変異（削除/改名/ディレクトリ）の再読込では入力欄から一度 focus が外れ、その
    // field editor の teardown（次 tick）が first responder を奪う。overlay 遷移と同じく次 tick で
    // focus を再確定して teardown に勝つ（定石の適用漏れを塞ぐ）。
    if model.overlay == .workspacePalette { reconfirmFocusNextTick() }
  }

  /// Cmd+,。設定パレットを開く（既に開いていれば再フォーカス）。
  func showSettingsPalette() {
    if model.overlay == .settingsPalette {
      model.settingsPalette?.focus()
      return
    }
    let values = ScopedSettingsValues(
      scope: .global,  // 開始は global スコープ
      global: settingsStore.global,
      override: current.settingsOverride ?? SettingsLayer())
    let p = SettingsPaletteModel(
      values: values,
      fontNames: FontCatalog.names(),
      allFontNames: FontCatalog.allNames(),  // タブタイトルフォント用（等幅制限なし）
      agents: agentLauncher.detectedCommands,  // 検出済みのみ（起動パレットと同じ検出結果）
      localization: localization,
      update: updateState,  // アップデートセクション（状態カード・トグル・今すぐ確認）
      worktreePreviewRoot: current.rootPath)  // worktree 作成先プレビューの基準（現 WS ルート）
    p.onApply = { [weak self] change, scope in self?.applySetting(change, scope: scope) }
    // 言語行（descriptor 非経由）: ストア更新→メインメニュー再構築→preferredLanguage 永続化を束ねる。
    p.onSelectLanguage = { [weak self] language in
      guard let self else { return }
      self.localization.language = language
      self.onLanguageChanged?()
      AppStatePersistence.update { $0.preferredLanguage = language.rawValue }
    }
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    model.settingsPalette = p
    model.overlay = .settingsPalette
    p.focus()
    reconfirmFocusNextTick()  // 別 overlay からの遷移で去りゆくカードの teardown に勝つ
  }

  /// 単一代入を、スコープに応じ global（settings.json）か workspace 上書き層へ保存し、実効設定で生成 conf を
  /// 再生成してライブ反映する（reload は applyActiveWorkspaceConfig が畳み込む）。設定パレット（onApply）・
  /// control `config_set`・AgentLauncher の default 設定が共用する（全設定が同じ 1 経路）。
  ///
  /// `target` は workspace スコープの書込先（省略時はアクティブ WS）。`Workspace` は参照型のため
  /// 非アクティブ WS でも `settingsOverride` を in-place で書ける。永続（scheduleSave）は常に、
  /// ライブ反映（applyActiveWorkspaceConfig）は global か対象がアクティブ WS の時だけ——非アクティブ
  /// WS の上書きは次回 activate 時に `current.settingsOverride` を読んで効く。
  func applySetting(
    _ change: SettingChange, scope: SettingsScope, target: Workspace? = nil
  ) {
    let target = target ?? current
    switch scope {
    case .global:
      settingsStore.applyGlobal(change)  // in-memory SSOT 変異＋即 save（書込 gate）
    case .workspace:
      var override = target.settingsOverride ?? SettingsLayer()
      override.apply(change)
      target.settingsOverride = override.isEmpty ? nil : override  // 空は上書き無しへ畳む
      scheduleSave()  // workspaces.json へ永続化（再起動越し復元）
    }
    if scope == .global || target === current { applyActiveWorkspaceConfig() }
  }

  /// ドメインA のライブ反映（hard reload）を trailing debounce で 1 回へ畳む。reloadConfig は
  /// 現在の gui.conf を読み直すだけで状態を持たないため、連続変更を最後の 1 回に集約して安全。
  func scheduleConfigReload() {
    pendingConfigReload?.cancel()
    // surface アルファ更新（reloadConfig）・NSWindow 透過再適用（syncWindowOpacity）・背景ブラー再適用
    // （syncWindowBlur）を同一 tick で揃える。syncWindowBlur は libghostty が更新後の config を読むため
    // 必ず reloadConfig の後に呼ぶ。
    let work = DispatchWorkItem { [weak self] in
      Ghostty.shared.reloadConfig()
      self?.syncWindowOpacity()
      self?.syncWindowBlur()
    }
    pendingConfigReload = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
  }

  /// Cmd+H。ヘルプオーバーレイ（ショートカットチートシート）を開く。閉じ側（トグル・esc・scrim）は
  /// dismissHelp。0タブでも開く（availableWithoutTabs）。
  func showHelp() {
    let m = HelpModel()
    m.onDismiss = { [weak self] in self?.dismissHelp() }
    model.help = m
    model.overlay = .help
    m.focus()
    reconfirmFocusNextTick()
  }

  /// ヘルプを畳み、アクティブペインへ first responder を戻す（パレット dismiss と同じ規則）。
  func dismissHelp() {
    model.help = nil
    model.overlay = .none
    focusActivePane()
    reconfirmFocusNextTick()
  }

  func dismissPalette() {
    model.overlay = .none
    model.languageSelect = nil
    model.workspacePalette = nil
    model.workspaceCreate = nil
    model.dispatchPalette = nil
    model.dispatchProvider = nil
    model.settingsPalette = nil
    model.help = nil
    focusActivePane()
    // teardown 後の次 tick で focus を再確定する。overlay==.none のままなら端末へ、直後に別 overlay へ
    // 差し替わっていれば（例: 切替パレットの ＋新規 → dismiss→作成フォーム）その overlay の入力欄へ当たる。
    reconfirmFocusNextTick()
  }

  /// Cmd+R。フォーカス中タブをタブ行内でその場編集する（中央パレットは出さない）。
  /// 現在の表示名（明示名 or 派生名②③）をプリフィルし、field editor で全選択して開く。
  func beginTabRename() {
    guard current.tabs.indices.contains(current.active) else { return }
    let tab = current.tabs[current.active]
    statusModel.editingIndex = current.active
    statusModel.editingText = tab.displayTitle(workspaceRoot: current.rootPath)  // 明示名 or 派生名
    statusModel.editingPlaceholder = tab.derivedTitle(workspaceRoot: current.rootPath)  // 空時の戻り先
    // クロージャは対象タブを弱参照する。tab を強参照すると改名タブの surface/pty がリークする。
    statusModel.onCommitRename = { [weak self, weak tab] name in
      guard let self else { return }
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      tab?.explicitTitle = trimmed.isEmpty ? nil : trimmed  // 空確定 → 解除（②③へ戻る）
      self.refreshChrome()
      self.scheduleSave()  // 明示タイトルを永続化（再起動越し復元）
      self.endTabRename()
    }
    statusModel.onCancelRename = { [weak self] in self?.endTabRename() }
    statusModel.editFocusToken &+= 1  // 描画後に field editor へ first responder
  }

  /// インライン改名を畳み、アクティブペインへ first responder を戻す（パレット dismiss と同じ規則）。
  func endTabRename() {
    statusModel.editingIndex = nil
    focusActivePane()
  }
}

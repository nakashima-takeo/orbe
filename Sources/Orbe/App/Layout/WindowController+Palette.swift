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
        self.focusSelection()
      } else {
        self.model.focusCurrentOverlayField()
      }
    }
  }

  /// 起動時の初回フロー。preferredLanguage 未設定なら言語選択を Onboarding の前段に出し、確定後に
  /// 既存 Onboarding へ進む。言語ゲートは Onboarding ゲート（導入済みフラグ ＋ 同梱プラグイン有無）とは独立。
  /// Home のフォルダは雛形の言語が要るので、言語選択の確定時に用意する（選択済みなら init が用意済み）。
  func showFirstRunFlow() {
    if AppStatePersistence.load()?.preferredLanguage == nil {
      showLanguageSelect { [weak self] in
        self?.prepareHomeFolder()
        self?.agentLauncher.showOnboardingIfNeeded()
      }
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
    p.onCreateFlow = { [weak self] name in
      self?.dismissPalette()
      self?.showWorkspaceCreate(name: name)
    }
    p.onRename = { [weak self] i, name in
      self?.renameWorkspace(i, to: name)
      self?.reloadPalette()
    }
    p.onSetDir = { [weak self] i, dir in
      self?.setWorkspaceDir(i, to: dir)
      self?.reloadPalette()
    }
    p.onClose = { [weak self] i in self?.closeWorkspace(i, origin: .gesture) }
    p.onDismiss = { [weak self] in self?.dismissPalette() }
    model.workspacePalette = p
    model.overlay = .workspacePalette
    reloadPalette()
    p.selectActiveRow()  // 開いた直後の選択カーソルをアクティブ workspace 行へ載せる
    p.focus()
    reconfirmFocusNextTick()  // 去りゆくカード（作成フォーム等）の teardown に focus を奪われないよう次 tick で再確定
  }

  /// 切替パレット末尾の「＋ 新規ワークスペース」。ソース切替（既存フォルダ / git clone）で workspace を
  /// 作る専用フォーム。`name` 非 nil でリンク解除状態の名前を引き継ぐ。dismiss は切替画面（⌘⇧S パレット）へ戻す。
  func showWorkspaceCreate(name: String?) {
    // パス初期値＝新しい workspace の root の既定（`~` 短縮）。clone 先の親も同じ初期値（model init）。
    let initialPath = (store.defaultNewWorkspaceRoot() as NSString).abbreviatingWithTildeInPath
    let m = WorkspaceCreateModel(path: initialPath, name: name, localization: localization)
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

  func reloadPalette() {
    let items = workspaces.enumerated().map { entry in
      WorkspacePaletteModel.Item(
        index: entry.offset, name: entry.element.name,
        isActive: entry.offset == activeWorkspace, dir: entry.element.rootPath,
        canSetDir: store.canChangeDir(entry.offset),
        canClose: store.removalBlocker(entry.offset) == nil,
        live: entry.element.paletteLiveState())
    }
    // Home を最上段、起源 workspace（配列で最初の通常 workspace）を 2 段目に MRU より優先して
    // 固定する（改名しても位置は同じ）。残りは最近使った順（MRU）: lastUsedAt 降順、同時刻・未設定
    // （旧データは全 nil）は元 offset 昇順で安定化し作成順を保つ（sorted は安定保証なしのため offset を
    // タイブレークに使う）。休眠（dormant）は位置のまま行ごと減光する別軸信号——末尾固定はしない。
    let origin = store.originWorkspaceIndex
    let order = workspaces.enumerated().sorted { a, b in
      let homeA = store.isHome(a.offset)
      if homeA != store.isHome(b.offset) { return homeA }
      if (a.offset == origin) != (b.offset == origin) { return a.offset == origin }
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

  /// パレット表示中の行チップ（状態集計・行の減光）を実状態へ追随させる。構造（名前・並び・アクティブ印）は
  /// 触らないので、絞り込み・選択カーソル・focus・詳細メニューへ潜っている状態は一切動かない。
  /// chrome ストリップと同じ coalesce 点（`flushChrome`）から流れる。
  func refreshWorkspacePaletteLiveStates() {
    guard model.overlay == .workspacePalette else { return }
    model.workspacePalette?.updateLiveStates(workspaces.map { $0.paletteLiveState() })
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

  /// ヘルプを畳み、選んでいるものへ first responder を戻す（パレット dismiss と同じ規則）。
  func dismissHelp() {
    model.help = nil
    model.overlay = .none
    focusSelection()
    reconfirmFocusNextTick()
  }

  func dismissPalette() {
    settleTaskPaletteEditing()
    model.overlay = .none
    model.languageSelect = nil
    model.workspacePalette = nil
    model.workspaceCreate = nil
    model.worktreePalette = nil
    model.worktreePaletteProvider = nil
    model.taskPalette = nil
    model.settingsPalette = nil
    model.attentionPalette = nil
    model.closedAgentsPalette = nil
    model.help = nil
    focusSelection()
    // teardown 後の次 tick で focus を再確定する。overlay==.none のままなら選んでいるものへ、直後に別 overlay へ
    // 差し替わっていれば（例: 切替パレットの ＋新規 → dismiss→作成フォーム）その overlay の入力欄へ当たる。
    reconfirmFocusNextTick()
  }

  /// Cmd+R。フォーカス中タブをタブ行内でその場編集する（中央パレットは出さない）。
  /// 現在の表示名（明示名 or 派生名②③）をプリフィルし、field editor で全選択して開く。
  func beginTabRename() {
    guard let tab = activeTab, let index = current.selectedTabIndex else { return }
    statusModel.editingIndex = index
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

  /// インライン改名を畳み、焦点をその時点の前面へ戻す（`reconfirmFocusNextTick` と同じ分岐）。overlay が
  /// 無ければ選んでいるものへ、あればその入力欄へ——改名中に「＋」や Attention でパレットを開くと、改名欄の
  /// blur がここへ来る。タブへ戻すとパレットが見えているのに打鍵が端末へ流れる。
  func endTabRename() {
    statusModel.editingIndex = nil
    if model.overlay == .none {
      focusSelection()
    } else {
      model.focusCurrentOverlayField()
    }
  }
}

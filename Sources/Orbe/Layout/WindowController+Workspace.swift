import AppKit

/// workspace の切替・作成・改名・ディレクトリ設定・削除と、空（0タブ）workspace のアクティブ化。
/// WindowController 本体からタブ管理・復元・chrome 更新と関心を分離する。
extension WindowController {
  func switchWorkspace(to index: Int) {
    guard store.setActiveWorkspace(index) else { return }
    activateCurrent()
    scheduleSave()
  }

  /// アクティブ workspace が0タブのときの content 掃除。全 subview（前タブ/前 WS のビュー）を外し、
  /// 除去済み surface に宙ぶらりんの first responder が残らないよう nil 化し、空状態の chrome を投影する。
  /// シェルは起こさない。`closeTab`（本体）と `activateCurrent` の双方から呼ぶため internal。
  func clearActiveContent() {
    model.content.subviews.forEach { $0.removeFromSuperview() }
    model.contentIsEmpty = true  // 0タブの地を AppShell が baseFill で埋める（透過越しの透け防止）
    // overlay 非表示時のみ first responder を落とす（0タブ時 ⌘W が dangling surface に届かないことを保証）。
    // overlay 表示中はパレットが first responder のため奪わない（select と同じ不変条件）。
    if model.overlay == .none { window.makeFirstResponder(nil) }
    refreshChrome()
  }

  /// アクティブ workspace を表示する。0タブなら空表示（シェルは起こさない）、非0タブなら select。
  /// 切替・復元・明示削除後の MRU 繰上げの全アクティブ化経路がここを共有する。
  func activateCurrent() {
    if current.tabs.isEmpty {
      clearActiveContent()  // 0タブ WS のアクティブ化は空状態を表示する（自動シェル起こしはしない）
    } else {
      select(current.active)
    }
    applyActiveWorkspaceConfig()  // 実効設定（外観＋gui.conf）は0タブでも従来どおり反映する
  }

  /// workspace を新規作成してアクティブ化し、その id を返す（name 空なら nil）。UI（パレットの onCreate）と
  /// control `create_workspace` が共用する。rootPath 省略時はアクティブペインの cwd → ホームを導出する。
  @discardableResult
  func createWorkspace(name: String, rootPath: String? = nil) -> Int? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let root =
      rootPath ?? store.activePaneCwd() ?? FileManager.default.homeDirectoryForCurrentUser.path
    store.createWorkspace(name: trimmed, rootPath: root)  // 空 WS を作りアクティブ化する（`~` 展開して格納）
    // 新規 WS は「作成して開く＝作業を始める」意図。0タブ休眠のアクティブ化（自動起こしなし）と違い、
    // ここは rootPath で1シェルを明示 spawn する。initialCwd は格納後の `current.rootPath`（`~` 展開済み）
    // を使う。newTab() は initialCwd 無しで初回シェルがホームに開くため使わない。
    store.appendTabToActive(wire(TerminalController(initialCwd: current.rootPath)))
    select(current.tabs.count - 1)
    applyActiveWorkspaceConfig()  // 新 WS は上書き無し＝global 実効へ。前 WS の上書き conf を持ち越さない
    scheduleSave()
    return store.current.id  // append 直後にアクティブ化されるため current が新規 WS
  }

  func renameWorkspace(_ index: Int, to name: String) {
    guard store.renameWorkspace(index, to: name) else { return }
    if index == activeWorkspace { refreshChrome() }
    scheduleSave()
  }

  /// workspace のディレクトリ設定（rootPath）を変更する。新規作成時のシェル起動 cwd と、
  /// タブタイトルの相対パス基点に使われる。`~` はホーム展開する。
  func setWorkspaceDir(_ index: Int, to path: String) {
    guard store.setWorkspaceDir(index, to: path) else { return }
    if index == activeWorkspace { refreshChrome() }  // displayTitle の相対パス基点が変わる
    scheduleSave()
  }

  /// workspace を閉じる（WorkspacePalette の明示削除）。最後の 1 つは残す。
  func closeWorkspace(_ index: Int) {
    switch store.closeWorkspace(index) {
    case .invalid:
      return
    case .activeChanged:
      activateCurrent()  // MRU 繰上げ先が0タブなら空表示（シェルは起こさない）
    case .backgroundChanged:
      refreshChrome()  // 背景 workspace の畳み込みでも chrome 横断 rollup を同期する
    }
    reloadPalette()  // パレット表示中の外因変異（shell exit 等）でも表示を実状態へ追従させる
    scheduleSave()
  }
}

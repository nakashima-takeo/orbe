import AppKit

/// アクティブ workspace の選択（ボード・タブ・空）の描画と巡回、選んでいるものへの焦点の戻し。
extension WindowController {
  func nextTab() {
    guard let selection = store.nextSelection() else { return }
    select(selection)
  }
  func prevTab() {
    guard let selection = store.prevSelection() else { return }
    select(selection)
  }

  /// アクティブ workspace の位置 `index` のタブを選ぶ（タブ行の位置の口）。範囲外は無視。
  func select(_ index: Int) {
    guard current.tabs.indices.contains(index) else { return }
    select(.tab(current.tabs[index]))
  }

  /// アクティブ workspace の選択を描く唯一の入口（アクティブ化・クリック・巡回・閉鎖後・`focus_tab`）。
  /// 不変条件: model.content はアクティブ workspace の全タブの view（ボードを持てばボードの器も）を保持し、選んでいる
  /// ものだけ可視・他は isHidden（他 WS のビューは外す。surface は keep-alive）。可視タブは即時 mount し、
  /// 未 mount の隠れタブは後続 tick へ分割 mount（surface 誕生を 1 turn で N 個積まない）。全タブは
  /// 最終的に mount され viewDidMoveToWindow で surface が誕生。閉じたタブの view を content から外す唯一の経路でもある。
  func select(_ selection: Workspace.Selection) {
    guard store.recordSelection(selection) else { return }
    // 選択が動いた＝インライン改名の文脈が崩れる。編集中なら畳む（DragSession と同じ「集合/選択が
    // 変わったら継続は不正」不変条件。blur 自己修復に頼らず SSOT 遷移点で決定的に解除する）。
    if statusModel.editingIndex != nil { endTabRename() }
    // 空のときだけ 0タブ backstop が地を塗る（タブは surface が、ボードは器が地を塗る＝二重 veil 回避）。
    model.contentIsEmpty = selection == .empty
    let ws = current
    let board = store.hasBoard(ws) ? boardView : nil
    // アクティブ WS に属さないビュー（前 WS のタブ・閉じたタブ・ボードを持たない WS でのボード）を外す。
    // surface は keep-alive で生存。
    var wanted = Set(ws.tabs.map { ObjectIdentifier($0.view) })
    if let board { wanted.insert(ObjectIdentifier(board)) }
    for sub in model.content.subviews where !wanted.contains(ObjectIdentifier(sub)) {
      sub.removeFromSuperview()
    }
    if let board { mountBoard(board, visible: selection == .board) }
    // 可視タブを同期 mount（即操作可能に＝この turn の surface 誕生を 1 枚へ上限化）。既 mount の
    // 隠れタブは isHidden/frame を即時更新（既に surface 在りで安価）。未 mount の隠れタブの
    // surface 誕生は後続 tick へ分割し、1 turn で N 個まとめて生成して固まるのを防ぐ。
    let selectedTab = ws.selectedTab
    for tab in ws.tabs where tab === selectedTab || tab.view.superview === model.content {
      mountTab(tab, in: ws, visible: tab === selectedTab)
    }
    // overlay 表示中は入力を奪わない（フォーカス復帰は dismiss 側が担う）。
    if model.overlay == .none { focusSelection() }
    consumeVisibleTabDone()
    refreshChrome()
    scheduleHiddenMounts(for: ws)
  }

  private func mountBoard(_ board: BoardView, visible: Bool) {
    board.frame = model.content.bounds
    board.isHidden = !visible
    if board.superview !== model.content {
      board.autoresizingMask = [.width, .height]
      model.content.addSubview(board)
    }
  }

  /// タブ 1 枚を model.content へ mount（surface 誕生は viewDidMoveToWindow 経由で冪等に 1 度）。
  /// 隠れタブも実サイズで起こす（pty winsize 正常）。frame/isHidden は既 mount でも毎回更新し、
  /// addSubview より先に確定させる——窓に付いた瞬間の可視性で面（エクスプローラー）が根のサービスを
  /// 握るか決まるので、隠れタブを一瞬でも見えている扱いにしない（`materializeOffscreen` と同じ順）。
  func mountTab(_ tab: TerminalTab, in ws: Workspace, visible: Bool) {
    guard store.recordMaterialization(of: tab, in: ws) else { return }
    tab.view.frame = model.content.bounds
    tab.view.isHidden = !visible
    if tab.view.superview !== model.content {
      tab.view.autoresizingMask = [.width, .height]
      tab.view.layoutSubtreeIfNeeded()
      model.content.addSubview(tab.view)
    }
  }

  /// 未 mount の隠れタブを後続 runloop tick で 1 枚ずつ mount（surface 誕生を分割）。
  /// 全タブ最終 mount・resume 起動を保つ。フラッシュ時に対象 WS がまだアクティブか
  /// 確認し、切替済みなら破棄して孤児 addSubview を防ぐ（次のアクティブ化でまた mount 対象＝冪等）。
  private func scheduleHiddenMounts(for ws: Workspace) {
    guard ws.tabs.contains(where: { $0.view.superview !== model.content }) else { return }
    DispatchQueue.main.async { [weak self, weak ws] in
      guard let self, let ws, self.current === ws else { return }
      guard let tab = ws.tabs.first(where: { $0.view.superview !== self.model.content })
      else { return }
      self.mountTab(tab, in: ws, visible: false)  // 隠れタブ＝不可視（surface 誕生・resume は走る）
      self.scheduleHiddenMounts(for: ws)
    }
  }

  /// 選んでいるものへフォーカスを戻す——タブなら焦点の面（端末 surface かエディター pane）、ボードならボードの中の宛先、
  /// 空なら無し（除去済みの surface に宙ぶらりんの first responder を残さない）。パレットの dismiss・workspace の切替・
  /// `focus_tab` が共有する。
  func focusSelection() {
    switch current.selection {
    case .tab(let tab): window.makeFirstResponder(tab.focusTarget)
    case .board: board.focus()
    case .empty: window.makeFirstResponder(nil)
    }
  }
}

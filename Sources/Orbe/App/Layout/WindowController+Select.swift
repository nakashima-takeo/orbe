import AppKit

/// アクティブ workspace の選択（ボード・タブ・空）を選ぶ命令と巡回、今の状態を画面へ写す描画、選んでいるものへの焦点の戻し。
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

  /// アクティブ workspace の選択を選ぶ（クリック・巡回・新しいタブ・`focus_tab`・閉じたエージェントを戻す・ボード）。
  /// 選択を記録して描く。不変条件に反する選択は何もしない。
  func select(_ selection: Workspace.Selection) {
    guard store.recordSelection(selection) else { return }
    renderSelection()
  }

  /// アクティブ workspace の今の状態を画面へ写す（冪等。状態を変えた経路の終わりに 1 回呼ぶ）。選んでいるタブを即時に
  /// materialize してから content を照合し（`reconcileContent`。見せるものは照合が状態から導く）、焦点を選んでいるものへ
  /// 戻す。未 materialize の隠れタブは後続 tick へ分割して起こす（surface 誕生を 1 turn で N 個積まない）。選択を記録
  /// し直さないので、選択を動かさない経路（タブの閉鎖の後・workspace のアクティブ化・選ばずに足したタブ）はこれだけを呼ぶ。
  func renderSelection() {
    // 選択が動きうる＝インライン改名の文脈が崩れる。編集中なら畳む（DragSession と同じ「集合/選択が
    // 変わったら継続は不正」不変条件。blur 自己修復に頼らず SSOT 遷移点で決定的に解除する）。
    if statusModel.editingIndex != nil { endTabRename() }
    let ws = current
    if let tab = ws.selectedTab { store.recordMaterialization(of: tab, in: ws) }
    reconcileContent()
    if store.hasBoard(ws) { projectBoardWidgets() }
    // overlay 表示中は入力を奪わない（フォーカス復帰は dismiss 側が担う）。
    if model.overlay == .none { focusSelection() }
    consumeVisibleTabDone()
    refreshChrome()
    scheduleHiddenMounts(for: ws)
  }

  /// 前面の workspace のボードのウィジェットの並びをボードへ写す唯一の口（`renderSelection` と、ウィジェットの操作の後）。
  func projectBoardWidgets() {
    board.show(store.boardWidgets(of: current) ?? [])
  }

  /// タブ 1 枚を materialize し（休眠チケットの消費と起動指示の確定）、content を照合する。端末はそこで連の器へ差さり、
  /// 窓に付いた時点で surface が生まれる（冪等に 1 度）。
  func mountTab(_ tab: TerminalTab, in ws: Workspace) {
    guard store.recordMaterialization(of: tab, in: ws) else { return }
    reconcileContent()
  }

  /// 未 materialize の隠れタブを後続 runloop tick で 1 枚ずつ起こす（surface 誕生を分割）。
  /// 全タブ最終 mount・resume 起動を保つ。フラッシュ時に対象 WS がまだアクティブか
  /// 確認し、切替済みなら破棄する（次のアクティブ化でまた対象＝冪等）。
  private func scheduleHiddenMounts(for ws: Workspace) {
    guard ws.tabs.contains(where: { !$0.activated }) else { return }
    DispatchQueue.main.async { [weak self, weak ws] in
      guard let self, let ws, self.current === ws else { return }
      guard let tab = ws.tabs.first(where: { !$0.activated }) else { return }
      self.mountTab(tab, in: ws)  // 隠れタブ＝不可視（surface 誕生・resume は走る）
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

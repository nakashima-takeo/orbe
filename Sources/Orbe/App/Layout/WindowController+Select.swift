import AppKit

/// アクティブ workspace の選択（ボード・タブ・空）を選ぶ命令と巡回、今の状態を画面へ反映する描画、選んでいるものへのフォーカスの戻し。
extension WindowController {
  func nextTab() {
    guard let selection = store.nextSelection() else { return }
    select(selection)
  }
  func prevTab() {
    guard let selection = store.prevSelection() else { return }
    select(selection)
  }

  /// アクティブ workspace の位置 `index` のタブを選ぶ（タブ行の位置を渡す入口）。範囲外は無視。
  func select(_ index: Int) {
    guard current.tabs.indices.contains(index) else { return }
    select(.tab(current.tabs[index]))
  }

  /// アクティブ workspace の選択を選ぶ（クリック・巡回・新しいタブ・閉じたエージェントを戻す・ボード）。エディターを閉じて
  /// 描く——タブは端末で出る。
  func select(_ selection: Workspace.Selection) {
    select(selection, inWorkspaceAt: activeWorkspace)
  }

  /// `index` の workspace で `selection` を選び（前面でなければ、その workspace へ移る）、1 回だけ描く。`inEditor` なら選んだ
  /// タブをエディターで見せ、そうでなければエディターを閉じる（タブは端末で出る）。`closingBrowser` なら開いているブラウザを
  /// 右シートも含めて閉じる（既定は全面のみ閉じて右シートを残す）。workspace・選択・エディターで見せるタブを
  /// すべて書いてから描く——先に workspace の切替を描くと、移り先ではないタブが一瞬「見ているタブ」になり、その done が消える。
  /// 動きを付けるのは、同じ workspace で選択が替わらず見せ方だけが変わるときだけ。範囲外の index と、不変条件に反する選択は
  /// 何もしない。workspace を替えたら、実効設定を反映して保存を予約する。
  func select(
    _ selection: Workspace.Selection, inWorkspaceAt index: Int, inEditor: Bool = false,
    closingBrowser: Bool = false
  ) {
    let switches = index != activeWorkspace
    let inPlace = !switches && current.selection == selection
    guard store.recordSelection(selection, inWorkspaceAt: index) else { return }
    yieldBrowserToUnderlay(animated: inPlace, closingSheet: closingBrowser)
    editorShownTab = inEditor ? current.selectedTab : nil
    renderSelection(animated: inPlace)
    guard switches else { return }
    applyActiveWorkspaceConfig()
    scheduleSave()
  }

  /// アクティブ workspace の今の状態を画面へ反映する（冪等。状態を変えた経路の終わりに 1 回呼ぶ）。最初に、エディターで見せて
  /// いるタブが今選んでいるタブでなければ無しにする（見せるタブが替わればエディターは閉じる）。`animated` なら、選んでいる
  /// タブの連の器へ見せ方を動きつきで写す（同じタブのまま開閉が変わる命令だけが渡す）。選んでいるタブを即時に materialize
  /// してから content を照合し（`reconcileContent`。見せるものは照合が状態から導く）、フォーカスを見せているものへ戻す。
  /// 未 materialize の隠れタブは後続 tick へ分割して materialize する（surface 誕生を 1 turn で N 個積まない）。選択を記録し直さない
  /// ので、選択を動かさない経路（タブの閉鎖の後・workspace のアクティブ化・選ばずに足したタブ）はこれだけを呼ぶ。
  func renderSelection(animated: Bool = false) {
    let ws = current
    if let shown = editorShownTab, shown !== ws.selectedTab { editorShownTab = nil }
    if animated, let tab = ws.selectedTab {
      tab.group.view.show(facesMode(of: tab.group), animated: true)
    }
    // 選択が動きうる＝インライン改名の文脈が崩れる。編集中なら畳む（DragSession と同じ「集合/選択が
    // 変わったら継続は不正」不変条件。blur 自己修復に頼らず SSOT 遷移点で決定的に解除する）。
    if statusModel.editingIndex != nil { endTabRename() }
    if let tab = ws.selectedTab { store.recordMaterialization(of: tab, in: ws) }
    reconcileContent()
    browserView.setPeekUnderlay(browserPeekUnderlay)
    if store.hasBoard(ws) { projectBoardWidgets() }
    // overlay 表示中は入力を奪わない（フォーカス復帰は dismiss 側が担う）。
    if model.overlay == .none { focusSelection() }
    MainActor.assumeIsolated {
      browserSession.syncCurrentWorkspace(ws.id, name: ws.name)
    }
    consumeVisibleTabDone()
    refreshChrome()
    scheduleHiddenMounts(for: ws)
  }

  /// 前面の workspace のボードのウィジェットの並びをボードへ反映する唯一の入口（`renderSelection` と、ウィジェットの操作の後）。
  func projectBoardWidgets() {
    board.show(store.boardWidgets(of: current) ?? [])
  }

  /// タブ 1 枚を materialize し（休眠チケットの消費と起動指示の確定）、content を照合する。端末はそこで連の器へ差さり、
  /// 窓に付いた時点で surface が生まれる（冪等に 1 度）。
  func mountTab(_ tab: TerminalTab, in ws: Workspace) {
    guard store.recordMaterialization(of: tab, in: ws) else { return }
    reconcileContent()
  }

  /// 未 materialize の隠れタブを後続 runloop tick で 1 枚ずつ materialize する（surface 誕生を分割）。
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

  /// 見せているものへフォーカスを戻す——タブの端末ならその surface、タブのエディター（透かしを含む）ならエディター面のフォーカスの行き先、
  /// ボードならボードの中の宛先、空なら無し（除去済みの surface に宙ぶらりんの first responder を残さない）。パレットの
  /// dismiss・workspace の切替・`focus_tab` が共有する。
  func focusSelection() {
    if browserMode == .full || (browserMode == .sheet && browserWasFocused) {
      if !browserView.focusIsInside { browserView.focusBrowser() }
      return
    }
    switch presentation {
    case .terminal(let tab): window.makeFirstResponder(tab.surface)
    case .editor(let tab), .peek(let tab): tab.group.view.editor.focusEditor()
    case .board: board.focus()
    case .empty: window.makeFirstResponder(nil)
    }
  }

}

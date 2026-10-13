import AppKit

/// タブを閉じる合流点と、人の操作のときだけ挟む未保存の確認。
extension WindowController {
  /// タブを閉じる唯一の合流点。発火源はユーザー操作（Cmd+W・中クリック）に限らず、shell の exit
  /// （close_surface_cb → onClose）が背景タブ・背景 workspace からも届くため、
  /// アクティブ文脈を前提にせず所属 workspace を特定して処理する。
  /// 制御 API（`close_tab`）も id 解決の上でここへ委譲する（WindowController+Control）ため internal。
  /// 人の操作（`.gesture`）で連の最後のタブを閉じるとき、連のエディターに未保存の文書があれば sheet で確認してから
  /// 閉じる——保存が外部変更で失敗すれば閉じない。連の途中のタブは問わない（エディターは残る）。シェル終了・制御 API で
  /// 連の最後のタブが閉じたときは黙って捨てる。応答が返るまでにタブが消えて
  /// いれば（シェル終了）何もしない。`runModal` は使わない——`tab.close` は main-queue のブロックから
  /// 届き、その中のモーダルは端末描画と制御 API を止める（`WindowController+Quit` の注記）。
  func closeTab(_ tab: TerminalTab?, origin: TabCloseOrigin) {
    guard let tab else { return }
    let unsaved =
      origin == .gesture && isLastOfGroup(tab) ? tab.group.unsavedDocuments() : []
    guard !unsaved.isEmpty else {
      performClose(tab, origin: origin)
      return
    }
    confirmDiscard(unsaved) { [weak self, weak tab] in
      guard let self, let tab else { return }
      self.performClose(tab, origin: origin)
    }
  }

  /// タブが、所属の workspace の中で連の最後の 1 枚か。
  private func isLastOfGroup(_ tab: TerminalTab) -> Bool {
    guard let ws = workspaces.first(where: { $0.tabs.contains { $0 === tab } }) else {
      return false
    }
    return !ws.tabs.contains { $0 !== tab && $0.group === tab.group }
  }

  /// `origin` は判断せず store へ素通しする（同一性の終わり方としてタブがログへ写す）。
  func performClose(_ tab: TerminalTab, origin: TabCloseOrigin) {
    // タブ集合が変わると editingIndex（位置 index）が別タブを指しうる。編集中なら畳む
    // （前方の背景タブが shell exit する等、フォーカスを保ったまま集合が変わる経路を決定的に解除）。
    if statusModel.editingIndex != nil { endTabRename() }
    switch store.removeTab(tab, origin: origin) {
    case .notFound:
      return
    case .activeTabsChanged:
      // 選択が動かなかった（隠れタブ・ボード選択中）close も必ず描き直す。照合が閉じたタブの端末を器から、空になった器を
      // content から外し（外さないと外れたタブの端末を器が retain し続け surface がリークする）、焦点を選んでいるものへ戻す。
      select(current.selection)
    case .backgroundChanged:
      reconcileContent()  // 閉じたタブの端末を器から外す（外さないと surface がリークする）
      refreshChrome()  // 背景タブ/背景 workspace の空化でも chrome 横断 rollup を同期する
    }
    reloadPalette()  // パレット表示中の外因変異（shell exit でのタブ消滅・0タブ化）でも表示を実状態へ追従させる
    scheduleSave()
  }
}

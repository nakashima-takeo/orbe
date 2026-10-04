import Foundation

/// 結果から一致を開く。開くのは出口（`open(_:_:)`）1 つ。クリック・キーで一致へ動いた（↑↓・→）は仮のタブで開いて焦点に
/// 触らず、ダブルクリック・Enter は普通のタブで開いて本文へ、F4 / ⇧F4 は仮のタブで開いて本文へ。キーで動いたときの開きは間引く——窓
/// （75ms）の外のリピートでない押下はすぐ開いて窓を始め、窓の中の押下とキーリピートは窓を延ばして待ち、窓が閉じたとき
/// その時点の選択が一致なら開く。押し続けている間は開かず、押し始めの 1 件と離した後の最後の 1 件だけを開く（1 回の開きは
/// ファイルを読むので、リピートの間隔ごとに開くと選択の移動が遅れる）。リピートを先頭にしないのは、押し始めから
/// リピートが始まるまでの初期遅延が窓より長く、時間だけでは押し続けでも開くため。すぐ開く出口が待ちを捨てるので、
/// クリック・Enter・F4 の後に前の選択が遅れて開くことはない。
extension ProjectSearch {
  /// 一致の開き方（仮か普通か）と、本文へ焦点を移すか。移さないときは焦点に触らない（VS Code の `preserveFocus`）——
  /// 遅れて走る開きが、その間に人が移した焦点を奪わない。
  struct Opening: Equatable {
    let mode: EditorSession.OpenMode
    let focusesText: Bool

    /// クリック・キーで一致へ動いた: 仮で開き、焦点は結果の列のまま。
    static let browse = Opening(mode: .preview, focusesText: false)
    /// F4 / ⇧F4: 仮で開いて本文へ。
    static let step = Opening(mode: .preview, focusesText: true)
    /// ダブルクリック・Enter: 普通に開いて本文へ。
    static let commit = Opening(mode: .pinned, focusesText: true)
  }

  // MARK: - 開く

  /// 一致を開く唯一の出口。待っているキーの開きを捨てる。
  func open(_ id: RowID, _ opening: Opening) {
    hasPendingNavigation = false
    onOpen(id, opening)
  }

  /// キーで選択を動かした（↑↓・→）。窓の外のリピートでない押下ならすぐ開いて窓を始め、そうでなければ待って窓を延ばす。
  func selectionDidNavigate(isRepeat: Bool) {
    if isRepeat || isNavigationWindowOpen {
      hasPendingNavigation = true
    } else {
      openSelectedMatch()
    }
    isNavigationWindowOpen = true
    navigationDelay.run(after: Self.navigationWindow) { [weak self] in
      guard let self else { return }
      isNavigationWindowOpen = false
      if hasPendingNavigation { openSelectedMatch() }
    }
  }

  /// その時点の選択が一致なら仮で開く（見出し・選択なしは開かない）。
  private func openSelectedMatch() {
    hasPendingNavigation = false
    guard let selection, selection.match != nil else { return }
    open(selection, .browse)
  }

  // MARK: - マウス

  /// 一致のシングルクリック: 選んで仮で開く（焦点は結果に残る）。見出しのクリック: 開閉。
  func click(_ id: RowID) {
    select(id)
    guard id.match != nil else {
      toggleCollapse(id.path)
      return
    }
    open(id, .browse)
  }

  /// 一致のダブルクリック: 普通に開いてテキスト面へ焦点を移す。
  func doubleClick(_ id: RowID) {
    guard id.match != nil else { return }
    select(id)
    open(id, .commit)
  }
}

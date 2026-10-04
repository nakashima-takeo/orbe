import Foundation

/// 結果から一致を開く。開くのは出口（`open(_:_:)`）1 つ。クリック・キーで一致へ動いた（↑↓・→）は仮のタブで開いて焦点に
/// 触らず、ダブルクリック・Enter は普通のタブで開いて本文へ、F4 / ⇧F4 は仮のタブで開いて本文へ。
///
/// キーで動いたときの開きは間引く（1 回の開きはファイルを読むので、リピートごとに開くと選択の移動が遅れる）。窓（75ms）の外の
/// リピートでない押下はすぐ開いて窓を始め、窓の中の押下は待って窓を延ばす。押している間（キーリピートを含む）は開かず、
/// キーを離してから窓が閉じたとき、その時点の選択が一致なら開く——押し続けても開くのは押し始めの 1 件と離した後の最後の 1 件
/// だけ。押し続けを時間ではなく離したことで見るのは、リピートの間隔（macOS の既定は約 83〜90ms）も初期遅延も窓より長く、
/// 時間だけでは押している間に窓が切れるため。離したことが届かないとき（押したまま焦点が移る等）は、次のリピートでない押下・
/// すぐ開く操作・結果の列から焦点が外れたことで離したものとして扱う。すぐ開く出口が待ちを捨てるので、クリック・Enter・F4 の
/// 後に前の選択が遅れて開くことはない。
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

  /// 一致を開く唯一の出口。待っているキーの開きを捨て、押しているキーを離したものとして扱う。
  func open(_ id: RowID, _ opening: Opening) {
    hasPendingNavigation = false
    isNavigationKeyHeld = false
    onOpen(id, opening)
  }

  /// キーで選択を動かした（↑↓・→）。窓の外のリピートでない押下ならすぐ開いて窓を始め、そうでなければ待つ。
  func selectionDidNavigate(isRepeat: Bool) {
    if !isRepeat { isNavigationKeyHeld = false }
    if isRepeat || isNavigationKeyHeld || isNavigationWindowOpen {
      hasPendingNavigation = true
    } else {
      openSelectedMatch()
    }
    isNavigationKeyHeld = true
    if !isRepeat { startNavigationWindow() }
  }

  /// 結果の列のキーを離した（か、離したことが届かないまま焦点が外れた）。待ちがあれば、ここから窓が閉じたときに開く。
  func navigationKeyDidRelease() {
    guard isNavigationKeyHeld else { return }
    isNavigationKeyHeld = false
    if hasPendingNavigation { startNavigationWindow() }
  }

  private func startNavigationWindow() {
    isNavigationWindowOpen = true
    navigationDelay.run(after: Self.navigationWindow) { [weak self] in
      guard let self else { return }
      isNavigationWindowOpen = false
      if hasPendingNavigation, !isNavigationKeyHeld { openSelectedMatch() }
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

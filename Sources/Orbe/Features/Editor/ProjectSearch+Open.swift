import Foundation

/// 結果から一致を開く。開くのは出口（`open(_:_:)`）1 つ。クリック・キーで一致へ動いた（↑↓・→）は仮のタブで開いて焦点に
/// 触らず、ダブルクリック・Enter は普通のタブで開いて本文へ、F4 / ⇧F4 は仮のタブで開いて本文へ。キーで動いたときの開きは
/// 間引く（→ `RowNavigationThrottle`）。待っている開きは、すぐ開く出口（クリック・Enter・F4）と、人の注意が結果から移った
/// こと（結果の列から焦点が外れた・列の外を押した・パネルが隠れた）で捨てる。
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
    navigation.drop()
    onOpen(id, opening)
  }

  /// その時点の選択が一致なら仮で開く（見出し・選択なしは開かない）。
  func openSelectedMatch() {
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

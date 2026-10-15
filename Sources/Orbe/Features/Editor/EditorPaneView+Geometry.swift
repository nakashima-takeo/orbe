import AppKit
import OrbeEditorCore

/// 骨の幾何——レール｜サイドバー（開いているとき。狭い列では表示幅を切り詰める）｜列の頭｜本体——を解き、
/// `layout()` で host・本体・境の当たりを置く。
extension EditorPaneView {
  /// 左列の幅（レール ＋ 右の hairline、サイドバーが開いていれば ＋表示幅 ＋ hairline）。
  var sideWidth: CGFloat {
    Theme.Layout.editorRail + Theme.Stroke.hairline
      + (sidebar.isOpen ? shownSidebarWidth + Theme.Stroke.hairline : 0)
  }

  /// サイドバーの表示幅。記憶の幅を、本体に最低幅が残るところまで切り詰める（記憶は変えない——列が
  /// 広がれば記憶の幅に戻る）。列がそれでも足りなければ残りをそのまま分け、0 まで縮む。
  var shownSidebarWidth: CGFloat { min(sidebar.width, max(0, sidebarCeiling)) }

  /// 本体に最低幅を残したときのサイドバーの幅の上限。
  var sidebarCeiling: CGFloat {
    bounds.width - Theme.Layout.editorRail - Theme.Stroke.hairline * 2
      - Theme.Layout.editorBodyMinWidth
  }

  /// ドラッグ中の幅。上限は本体に最低幅が残るまで（下限は状態が守る）。列が狭くてサイドバーを下限まで
  /// も出せないときは掴んでも動かせないので、記憶に触れない。境が動かないドラッグ（切り詰め中に上限へ
  /// 押し付ける）も記憶を書き換えない——記憶は「境を動かした」ときだけ変わる。
  func resizeSidebar(to width: CGFloat) {
    let ceiling = sidebarCeiling
    guard ceiling >= Theme.Layout.editorSidebarMinWidth else { return }
    let target = min(width, ceiling)
    guard target != shownSidebarWidth else { return }
    sidebar.setWidth(target)
    needsLayout = true  // setWidth は立てない（観測は次のターン）。その場で置き直すために明示する。
    layoutSubtreeIfNeeded()
  }

  /// サイドバーの幅・開閉・パネルを観測して置き直す。閉じれば行内入力は終わり、検索パネルの見え隠れで一致の地を押し直す。
  /// この面の検索パネルにあった焦点は、パネルが隠れたら面の行き先へ戻す（サイドバーはアプリ全体で 1 つなので、全タブの面が
  /// 同時に受ける——焦点を持っていた面だけが動く）。
  func observeSidebar() {
    withObservationTracking {
      _ = sidebar.width
      _ = sidebar.isOpen
      _ = sidebar.panel
    } onChange: { [weak self] in
      // 変わる直前に呼ばれるので、焦点が検索パネルにあったかはここで取る。
      let hadPanelFocus = MainActor.assumeIsolated { self?.focusIsInSearchPanel == true }
      DispatchQueue.main.async {
        guard let self else { return }
        self.needsLayout = true
        if !self.sidebar.isOpen || self.sidebar.panel != .files { self.tree.cancelNew() }
        if hadPanelFocus, !self.showsSearchPanel { self.reclaimSidebarFocus() }
        self.pushFindGround()
        self.observeSidebar()
      }
    }
  }

  /// 列の頭の高さ（タブ行 ＋ 下の hairline、本体がパンくずを持てばパンくずも——空状態だけ持たない）。SwiftUI 側の
  /// パンくずの出し分けも同じ事実（`EditorShellModel.activeName`、本体の種類から作る）で決まる。
  var headerHeight: CGFloat {
    Theme.Layout.editorFileTabs + Theme.Stroke.hairline
      + (body.hasBreadcrumb ? Theme.Layout.editorBreadcrumb : 0)
  }

  /// 本体（文書の面・diff の面・文字だけの器）の矩形。
  var bodyRect: NSRect {
    NSRect(
      x: sideWidth, y: headerHeight, width: max(0, bounds.width - sideWidth),
      height: max(0, bounds.height - headerHeight))
  }

  /// 焦点の文書の面の右列（ミニマップ ＋ 縦スクロールバー）の幅。本体より広くはならない。文書が無ければ 0。
  var rightColumnWidth: CGFloat {
    min(bodyRect.width, document?.surface.rightColumnWidth ?? 0)
  }

  /// 検索バーの右端を、右列の左 `beat` に置く（右列の幅は本体の幅と行番号の列の桁で変わる）。
  func placeSearchBar() {
    let constant = -(rightColumnWidth + Theme.Space.beat)
    if searchBarTrailing?.constant != constant { searchBarTrailing?.constant = constant }
  }

  override func layout() {
    // 面の大きさが右列の幅を決め、検索バーの制約はその幅から置く——制約は super.layout() が当てるので、その前に置く。
    document?.surface.view.frame = bodyRect
    if let diff { layoutDiff(diff) }
    placeSearchBar()
    super.layout()
    let sideWidth = self.sideWidth
    sideHost.frame = NSRect(
      x: 0, y: 0, width: min(sideWidth, bounds.width), height: bounds.height)
    headerHost.frame = NSRect(
      x: sideWidth, y: 0, width: max(0, bounds.width - sideWidth), height: headerHeight)
    emptyHost.frame = bodyRect
    // 当たりは境を動かせるときだけ（`resizeSidebar` の guard と同じ条件）——動かない列に出すとレールの右 1pt を
    // 覆ってリサイズカーソルだけが出る。
    sidebarHandle.isHidden =
      !sidebar.isOpen || sidebarCeiling < Theme.Layout.editorSidebarMinWidth
    sidebarHandle.frame = NSRect(
      x: sideWidth - Theme.Stroke.hairline - Theme.Layout.editorSidebarHandle / 2, y: 0,
      width: Theme.Layout.editorSidebarHandle, height: bounds.height)
  }
}

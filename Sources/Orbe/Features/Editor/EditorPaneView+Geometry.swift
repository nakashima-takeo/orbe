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

  /// サイドバーの幅・開閉・パネルとアウトラインの開閉を観測して置き直す。閉じれば行内入力は終わり、検索パネルの見え隠れで
  /// 一致の地を押し直し、アウトラインの見え隠れを焦点の文書へ告げる。この面の検索パネル・アウトラインにあった焦点は、それが
  /// 隠れたら面の行き先へ戻す（サイドバーはアプリ全体で 1 つなので、全タブの面が同時に受ける——焦点を持っていた面だけが
  /// 動く）。
  func observeSidebar() {
    withObservationTracking {
      _ = sidebar.width
      _ = sidebar.isOpen
      _ = sidebar.panel
      _ = sidebar.isOutlineOpen
    } onChange: { [weak self] in
      // 変わる直前に呼ばれるので、焦点が検索パネル・アウトラインにあったかはここで取る。
      let hadPanelFocus = MainActor.assumeIsolated { self?.focusIsInSearchPanel == true }
      let hadOutlineFocus = MainActor.assumeIsolated { self?.focusIsInOutline == true }
      DispatchQueue.main.async {
        guard let self else { return }
        self.needsLayout = true
        if !self.sidebar.isOpen || self.sidebar.panel != .files { self.tree.cancelNew() }
        if hadPanelFocus, !self.showsSearchPanel { self.reclaimSidebarFocus() }
        if hadOutlineFocus, !self.showsOutline { self.reclaimSidebarFocus() }
        self.updateOutlineWant()
        self.pushFindGround()
        self.observeSidebar()
      }
    }
  }

  /// 列の頭の高さ（ファイルタブ行 ＋ 下の hairline、文書があればパンくずも）。
  var headerHeight: CGFloat {
    Theme.Layout.editorFileTabs + Theme.Stroke.hairline
      + (document != nil ? Theme.Layout.editorBreadcrumb : 0)
  }

  /// 本体（文書があればテキスト面と俯瞰、無ければ空状態）の矩形。
  var bodyRect: NSRect {
    NSRect(
      x: sideWidth, y: headerHeight, width: max(0, bounds.width - sideWidth),
      height: max(0, bounds.height - headerHeight))
  }

  /// 焦点の文書の面が自分で俯瞰を描くなら、その面。
  var overviewSurface: OverviewDrawingSurface? { document?.surface as? OverviewDrawingSurface }

  /// 今の面の俯瞰のミニマップの幅（VS Code の式。本文の幅から計算し、上限 `editorMinimapMaxWidth`）。
  var minimapWidth: CGFloat {
    MinimapLayout.width(
      remaining: bodyRect.width - Theme.Layout.editorLineNumberGutter
        - Theme.Layout.editorMarkGutter,
      charWidth: (" " as NSString).size(withAttributes: [.font: Theme.Typography.editorCode]).width,
      scrollbar: Theme.Layout.editorScrollbar, maxWidth: Theme.Layout.editorMinimapMaxWidth)
  }

  /// 右列の幅（ミニマップ ＋ スクロールバー）。自分で俯瞰を描く面なら面が答える幅。本体より広くはならない。
  var rightColumnWidth: CGFloat {
    min(
      bodyRect.width,
      overviewSurface?.rightColumnWidth ?? minimapWidth + Theme.Layout.editorScrollbar)
  }

  /// テキスト面の矩形——自分で俯瞰を描く面なら本体全体、そうでなければ本体から右列を除いたぶん。文書が無ければ本体
  /// そのもの。
  var surfaceRect: NSRect {
    guard document != nil, overviewSurface == nil else { return bodyRect }
    let body = bodyRect
    return NSRect(
      x: body.minX, y: body.minY, width: max(0, body.width - rightColumnWidth), height: body.height)
  }

  /// 今の面の俯瞰のミニマップの矩形（スクロールバーの左）。
  var minimapRect: NSRect {
    let body = bodyRect
    let scrollbarWidth = min(Theme.Layout.editorScrollbar, body.width)
    let width = max(0, rightColumnWidth - scrollbarWidth)
    return NSRect(
      x: body.maxX - scrollbarWidth - width, y: body.minY, width: width, height: body.height)
  }

  /// 今の面の俯瞰のスクロールバーの矩形（本体の右端）。
  var scrollbarRect: NSRect {
    let body = bodyRect
    let width = min(Theme.Layout.editorScrollbar, body.width)
    return NSRect(x: body.maxX - width, y: body.minY, width: width, height: body.height)
  }

  /// 検索バーの右端を、右列の左 `beat` に置く（右列の幅は本体の幅と、自分で俯瞰を描く面では行番号の列の桁で変わる）。
  func placeSearchBar() {
    let constant = -(rightColumnWidth + Theme.Space.beat)
    if searchBarTrailing?.constant != constant { searchBarTrailing?.constant = constant }
  }

  override func layout() {
    super.layout()
    let sideWidth = self.sideWidth
    sideHost.frame = NSRect(
      x: 0, y: 0, width: min(sideWidth, bounds.width), height: bounds.height)
    headerHost.frame = NSRect(
      x: sideWidth, y: 0, width: max(0, bounds.width - sideWidth), height: headerHeight)
    emptyHost.frame = bodyRect
    document?.surface.view.frame = surfaceRect
    appKitOverview.layout(surface: surfaceRect, minimap: minimapRect, scrollbar: scrollbarRect)
    placeSearchBar()
    // 本体の上のポインタの当たりは本体の矩形（サイドバーの幅で動く）。
    updateTrackingAreas()
    // 当たりは境を動かせるときだけ（`resizeSidebar` の guard と同じ条件）——動かない列に出すとレールの右 1pt を
    // 覆ってリサイズカーソルだけが出る。
    sidebarHandle.isHidden =
      !sidebar.isOpen || sidebarCeiling < Theme.Layout.editorSidebarMinWidth
    sidebarHandle.frame = NSRect(
      x: sideWidth - Theme.Stroke.hairline - Theme.Layout.editorSidebarHandle / 2, y: 0,
      width: Theme.Layout.editorSidebarHandle, height: bounds.height)
  }
}

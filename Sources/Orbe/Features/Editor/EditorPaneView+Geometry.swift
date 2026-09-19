import AppKit

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

  func observeSidebar() {
    withObservationTracking {
      _ = sidebar.width
      _ = sidebar.isOpen
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.needsLayout = true
        if !self.sidebar.isOpen { self.tree.cancelNew() }  // 閉じれば入力行は消える＝入力の終わり
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

  /// 俯瞰の列の幅（左の hairline ＋ ミニマップ ＋ 印の列）。
  var overviewWidth: CGFloat {
    Theme.Stroke.hairline + Theme.Layout.editorMinimap + Theme.Layout.editorScrollMarks
  }

  /// テキスト面の矩形（本体から右の俯瞰を除いたぶん）。文書が無ければ本体そのもの。
  var surfaceRect: NSRect {
    guard document != nil else { return bodyRect }
    let body = bodyRect
    return NSRect(
      x: body.minX, y: body.minY, width: max(0, body.width - overviewWidth), height: body.height)
  }

  /// 俯瞰の矩形（本体の右端）。
  var overviewRect: NSRect {
    let body = bodyRect
    return NSRect(
      x: body.maxX - overviewWidth, y: body.minY, width: overviewWidth, height: body.height)
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
    overview.frame = overviewRect
    // 当たりは境を動かせるときだけ（`resizeSidebar` の guard と同じ条件）——動かない列に出すとレールの右 1pt を
    // 覆ってリサイズカーソルだけが出る。
    sidebarHandle.isHidden =
      !sidebar.isOpen || sidebarCeiling < Theme.Layout.editorSidebarMinWidth
    sidebarHandle.frame = NSRect(
      x: sideWidth - Theme.Stroke.hairline - Theme.Layout.editorSidebarHandle / 2, y: 0,
      width: Theme.Layout.editorSidebarHandle, height: bounds.height)
    // 地の穴（テキスト面の矩形）は幾何の関数。subview の移動や frame の変更では層は描き直されない。
    needsDisplay = true
  }
}

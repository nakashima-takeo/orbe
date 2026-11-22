import AppKit
import OrbeEditorCore

/// 骨の幾何——上のバー（全幅）、その下に左の列（開いているとき。狭い面では表示幅を切り詰める）｜列の頭｜本体——を解き、
/// `layout()` で host・本体・境の当たりを置く。
extension EditorPaneView {
  /// 左の列の幅（開いていれば表示幅 ＋ 右の hairline、閉じていれば 0）。
  var sideWidth: CGFloat {
    sidebar.isOpen ? shownSidebarWidth + Theme.Stroke.hairline : 0
  }

  /// 左の列の表示幅。記憶の幅を、本体に最低幅が残るところまで切り詰める（記憶は変えない——面が
  /// 広がれば記憶の幅に戻る）。面がそれでも足りなければ残りをそのまま分け、0 まで縮む。
  var shownSidebarWidth: CGFloat { min(sidebar.width, max(0, sidebarCeiling)) }

  /// 本体に最低幅を残したときの左の列の幅の上限。
  var sidebarCeiling: CGFloat {
    bounds.width - Theme.Stroke.hairline - Theme.Layout.editorBodyMinWidth
  }

  /// ドラッグ中の幅。上限は本体に最低幅が残るまで（下限は状態が守る）。面が狭くて左の列を下限まで
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

  /// 左の列の幅・開閉と PR のパネルのツリーかリストかを観測して置き直す（左の列はアプリ全体で 1 つなので、全連の面が
  /// 同時に受ける——焦点を持っていた面だけが動く）。
  func observeSidebar() {
    withObservationTracking {
      _ = sidebar.width
      _ = sidebar.isOpen
      _ = sidebar.pullRequestFilesAsTree
    } onChange: { [weak self] in
      // 変わる直前に呼ばれるので、焦点がどのパネルにあったかはここで取る。
      let held = MainActor.assumeIsolated { self?.panelHoldingFocus }
      DispatchQueue.main.async {
        guard let self else { return }
        self.sidebarDidChange(held: held)
        self.observeSidebar()
      }
    }
  }

  /// 左の列の中身を、今の画面と Files の左の列の中身に合わせる（セッションの変化と、Files の左の列の中身の変化で呼ぶ）。
  func syncPanel() {
    let next = EditorShellModel.Panel(screen: group?.editor.screen ?? .files, files: filesPanel)
    guard next != shell.panel else { return }
    let held = panelHoldingFocus
    shell.panel = next
    sidebarDidChange(held: held)
  }

  /// 左の列の開閉・中身・PR のパネルのツリーかリストかが変わった。置き直し、エクスプローラーが隠れれば行内入力は終わり、
  /// 検索パネルの見え隠れで一致の地を押し直し、画面で一覧が行を組むかを決め直し、PR のパネルの行を組み直す。この面の
  /// パネルにあった焦点（`held`）は、そのパネルが隠れたら面の行き先へ戻す。左の列を閉じたら、ソース管理パネルと PR の
  /// パネルは隠れたことにする（一覧は画面の間は行を組み続けるが、待っている開き・焦点の要求・欄の変換中の字は捨てる）。
  private func sidebarDidChange(held: EditorShellModel.Panel?) {
    needsLayout = true
    if !sidebar.isOpen || shell.panel != .files { tree.cancelNew() }
    if let held, !sidebar.isOpen || shell.panel != held { reclaimSidebarFocus() }
    if !sidebar.isOpen {
      scm.panelDidHide()
      pullRequest.panelDidHide()
    }
    updatePanelsShown()
    pullRequest.rebuild()
    pushFindGround()
  }

  /// 焦点を持っている左の列のパネル（検索パネル・ソース管理パネルの入力欄か列、PR のパネルの列か全体へのコメント欄）。
  var panelHoldingFocus: EditorShellModel.Panel? {
    switch shell.panel {
    case .files: return nil
    case .search: return focusIsInSearchPanel ? .search : nil
    case .sourceControl: return focusIsInSourceControl ? .sourceControl : nil
    case .pullRequest: return focusIsInPullRequest ? .pullRequest : nil
    }
  }

  /// 列の頭の高さ（タブ行 ＋ 下の hairline、本体がパンくずを持てばパンくずも——空状態だけ持たない）。SwiftUI 側の
  /// パンくずの出し分けも同じ事実（`EditorShellModel.activeName`、本体の種類から作る）で決まる。
  var headerHeight: CGFloat {
    Theme.Layout.editorFileTabs + Theme.Stroke.hairline
      + (body.hasBreadcrumb ? Theme.Layout.editorBreadcrumb : 0)
  }

  /// 本体（文書の面・diff の面・文字だけの器）の矩形——バーの下、左の列の右、列の頭の下。
  var bodyRect: NSRect {
    let top = Theme.Layout.editorBar + headerHeight
    return NSRect(
      x: sideWidth, y: top, width: max(0, bounds.width - sideWidth),
      height: max(0, bounds.height - top))
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
    let bar = Theme.Layout.editorBar
    let below = max(0, bounds.height - bar)
    barHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: min(bar, bounds.height))
    sideHost.frame = NSRect(x: 0, y: bar, width: min(sideWidth, bounds.width), height: below)
    headerHost.frame = NSRect(
      x: sideWidth, y: bar, width: max(0, bounds.width - sideWidth), height: headerHeight)
    faceHost.frame = bodyRect
    // 当たりは境を動かせるときだけ（`resizeSidebar` の guard と同じ条件）——動かない面に出すと本体の左 1pt を
    // 覆ってリサイズカーソルだけが出る。
    sidebarHandle.isHidden =
      !sidebar.isOpen || sidebarCeiling < Theme.Layout.editorSidebarMinWidth
    sidebarHandle.frame = NSRect(
      x: sideWidth - Theme.Stroke.hairline - Theme.Layout.editorSidebarHandle / 2, y: bar,
      width: Theme.Layout.editorSidebarHandle, height: below)
    // 待ちは本体の面の枠を置き終えた後に通す——文書は見えている範囲が、diff は最初の位置が、枠で決まる。
    prepareBodyIfVisible()
  }

  /// 面が画面に見えていれば、本体の文書・diff を初めて見せる前の上限つきの待ちを通す（2 回目以降は文書・diff が何もしない）。
  /// 隠れた面・窓に無い面では待たず、面が見えたときに待つ——エディターを閉じた連を復元しても main を止めない。呼ぶのは面の
  /// 配置（`layout()`）の最後だけ。配置は描く前に、main の runloop の 1 周の終わりか、利用者の操作の中の
  /// `layoutSubtreeIfNeeded()` で走り、どちらも文書の受け取りの知らせの外になる。受け取りの知らせの中から pane を同期で配置
  /// させない——`EditorDocument.prepareToShow` は受け取りの途中で呼ばれると、待たないときも precondition で止まる（待てば
  /// 同じ文書の受け取りが入れ子になる）。
  func prepareBodyIfVisible() {
    guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
    switch body {
    case .document(let document): document.prepareToShow()
    case .diff(let diff): diff.prepareToShow()
    case .empty: break
    }
  }

  /// 面を本体に載せる。境の当たり（hairline を跨ぐ 4pt）の右 1pt は本体と重なるので、テキスト面はその下。検索バーは後から
  /// 足すので面の上。
  func install(_ surface: any TextSurface) {
    surface.host = self
    let view = surface.view
    view.autoresizingMask = []
    view.frame = bodyRect
    addSubview(view, positioned: .below, relativeTo: sidebarHandle)
  }
}

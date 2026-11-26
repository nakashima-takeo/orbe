import AppKit
import OrbeEditorCore

/// 骨の幾何——上のバー（全幅）、その下に左の列（開いているとき。狭い面では表示幅を切り詰める）｜本体——を解き、
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
  /// 画面が替われば、面の中の確認をキャンセルで閉じ、ポップアップを閉じる。
  func syncPanel() {
    let next = EditorShellModel.Panel(screen: group?.editor.screen ?? .files, files: filesPanel)
    guard next != shell.panel else { return }
    let held = panelHoldingFocus
    if next.screen != shell.panel.screen {
      confirm.close(.itemGone)
      popup.close(.itemGone)
    }
    shell.panel = next
    sidebarDidChange(held: held)
  }

  /// 左の列の開閉・中身・PR のパネルのツリーかリストかが変わった。置き直し、エクスプローラーが隠れれば行内入力は終わり、
  /// 検索パネルの見え隠れで一致の地と今の項目（キーの札 ↵）を写し直し、画面で一覧が行を組むかを決め直し、PR のパネルの
  /// 行を組み直す。この面の
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
    refreshCurrentItem()
  }

  /// 焦点を持っている左の列のパネル（検索パネルの入力欄か列、ソース管理パネルの列、PR のパネルの列か全体へのコメント欄）。
  var panelHoldingFocus: EditorShellModel.Panel? {
    switch shell.panel {
    case .files: return nil
    case .search: return focusIsInSearchPanel ? .search : nil
    case .sourceControl: return focusIsInSourceControl ? .sourceControl : nil
    case .pullRequest: return focusIsInPullRequest ? .pullRequest : nil
    }
  }

  /// 本体（文書の面・diff の面・文字だけの器）の矩形——バーの下、左の列の右。
  var bodyRect: NSRect {
    let top = Theme.Layout.editorBar
    return NSRect(
      x: sideWidth, y: top, width: max(0, bounds.width - sideWidth),
      height: max(0, bounds.height - top))
  }

  /// 置き場の矩形——右端は面の右端から 12、上端はバーの下端から 6、幅は失敗の札の最大幅（面が狭ければ面の幅 − 24）、
  /// 高さはバーより下いっぱいから下の余白を引いた高さ。
  var dockRect: NSRect {
    let trailing = Theme.Layout.editorDockTrailing
    let width = max(0, min(Theme.Layout.editorDockWidth, bounds.width - trailing * 2))
    let top = Theme.Layout.editorBar + Theme.Layout.editorDockTop
    return NSRect(
      x: bounds.width - trailing - width, y: top, width: width,
      height: max(0, bounds.height - top - Theme.Layout.editorDockBottom))
  }

  /// 本体の上端の帯（差分の見出し）の高さ。本体が diff でなければ 0。
  var bodyBandHeight: CGFloat {
    diff == nil ? 0 : min(Theme.Layout.editorDiffHeader, bodyRect.height)
  }

  /// 本体のうち見出しの下の矩形（diff の面・文字だけの器を置く）。本体が diff でなければ本体の矩形そのもの。
  var belowHeaderRect: NSRect {
    let header = bodyBandHeight
    let body = bodyRect
    return NSRect(
      x: body.minX, y: body.minY + header, width: body.width, height: body.height - header)
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

  /// 骨の view を重ねる——下から、バーの地・バーより下（その地・左の列・文字だけの器・見出し・境の当たり・置き場。本体の面は
  /// 見出しの下に、検索バーは後から一番上に足す）・上のバー・面の中の確認（面いっぱい。出ている間だけ見せる）。
  func assembleViews() {
    for view in [barGround, belowGround, belowBar] {
      view.wantsLayer = true
      view.autoresizingMask = []
    }
    addSubview(barGround)
    addSubview(belowBar)
    belowBar.addSubview(belowGround)
    for host in [sideHost, faceHost, headerHost, barHost] as [NSView] {
      // SwiftUI 背景の alpha を窓まで通す（透過時に不透明ラスタで塞がない）。
      host.wantsLayer = true
      host.layer?.isOpaque = false
      host.autoresizingMask = []
      (host === barHost ? self : belowBar).addSubview(host)
    }
    sidebarHandle.autoresizingMask = []
    belowBar.addSubview(sidebarHandle)
    dockHost.wantsLayer = true
    dockHost.layer?.isOpaque = false
    dockHost.autoresizingMask = []
    belowBar.addSubview(dockHost)
    confirmHost.autoresizingMask = []
    confirmHost.isHidden = true
    addSubview(confirmHost)
    diffDivider.wantsLayer = true
    diffDivider.autoresizingMask = []
  }

  override func layout() {
    // 見せ方は面の枠を置く前に決める——並列とインラインで面の数が変わり、開いた直後に送る位置も見せ方で変わる。
    fitDiffMode()
    // 面の大きさが右列の幅を決め、検索バーの制約はその幅から置く——制約は super.layout() が当てるので、その前に置く。
    document?.surface.view.frame = bodyRect
    if let diff { layoutDiff(diff) }
    placeSearchBar()
    super.layout()
    let sideWidth = self.sideWidth
    let bar = Theme.Layout.editorBar
    let below = max(0, bounds.height - bar)
    barHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: min(bar, bounds.height))
    barGround.frame = barHost.frame
    belowBar.frame = bounds
    belowGround.frame = NSRect(x: 0, y: bar, width: bounds.width, height: below)
    sideHost.frame = NSRect(x: 0, y: bar, width: min(sideWidth, bounds.width), height: below)
    faceHost.frame = belowHeaderRect
    // 見出しの host は、帯の下にはみ出す影の分だけ高い（影の範囲は押下を素通しする）。
    headerHost.frame = NSRect(
      x: bodyRect.minX, y: bodyRect.minY, width: bodyRect.width,
      height: min(
        Theme.Layout.editorDiffHeader + Theme.Layout.editorDiffHeaderShadow, bodyRect.height))
    // 当たりは境を動かせるときだけ（`resizeSidebar` の guard と同じ条件）——動かない面に出すと本体の左 1pt を
    // 覆ってリサイズカーソルだけが出る。
    sidebarHandle.isHidden =
      !sidebar.isOpen || sidebarCeiling < Theme.Layout.editorSidebarMinWidth
    sidebarHandle.frame = NSRect(
      x: sideWidth - Theme.Stroke.hairline - Theme.Layout.editorSidebarHandle / 2, y: bar,
      width: Theme.Layout.editorSidebarHandle, height: below)
    layoutDock()
    layoutItemList()
    confirmHost.frame = bounds
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
    guard isFaceVisible else { return }
    switch body {
    case .document(let document): document.prepareToShow()
    case .diff(let diff): diff.prepareToShow()
    case .empty: break
    }
  }

  /// 面を本体に載せる。境の当たり（hairline を跨ぐ 4pt）の右 1pt は本体と重なり、見出しの影は面の上端に掛かるので、テキスト
  /// 面はどちらよりも下。検索バーは後から足すので面の上。
  func install(_ surface: any TextSurface) {
    surface.host = self
    let view = surface.view
    view.autoresizingMask = []
    view.frame = belowHeaderRect
    belowBar.addSubview(view, positioned: .below, relativeTo: headerHost)
  }
}

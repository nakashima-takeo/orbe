import AppKit
import OrbeEditorCore

/// 文書の「変わった」の扇出と、俯瞰（ミニマップ・スクロールバー・影）と出現の強調への配線。文書側の closure は単一の
/// まま、ここがミニマップ・スクロールバー・影・検索・出現の強調へ配る（裏から届いた役割と問いの結果も）。検索の一致と
/// 語の出現は束ねて（`OverviewDecorations`）ミニマップとスクロールバーへ押す。本体の上のポインタは pane の tracking area
/// が見て、スクロールバーのつまみの見え隠れに使う。
extension EditorPaneView {
  /// 文書の「変わった」を右列・影・検索・出現の強調へ配る（見せている文書だけ）。
  func observe(_ document: EditorDocument, _ on: Bool) {
    document.onViewportChange =
      on
      ? { [weak self] in
        guard let self else { return }
        minimap.refresh()
        scrollbar.refresh()
        noteScrollState()
        updateShadow()
      } : nil
    document.onHunksChange =
      on
      ? { [weak self] in
        self?.minimap.refresh()
        self?.scrollbar.refresh()
      } : nil
    document.onSelectionChange =
      on
      ? { [weak self] in
        guard let self else { return }
        minimap.refresh()
        scrollbar.refresh()
        search.selectionDidChange()
        occurrences.selectionDidChange()
      } : nil
    document.onTextChange =
      on
      ? { [weak self] edit in
        guard let self else { return }
        minimap.textDidChange(edit)
        scrollbar.refresh()
        noteScrollState()
        search.textDidChange(edit)
        occurrences.textDidChange()
      } : nil
    document.onRolesChange = on ? { [weak self] in self?.minimap.rolesDidChange($0) } : nil
    document.onAnalysis =
      on
      ? { [weak self] request, ranges in
        guard let self else { return }
        switch request {
        case .find(let needle): search.didFind(needle, ranges)
        case .selectionOccurrences: occurrences.didFindSelectionOccurrences(request, ranges)
        case .wordOccurrences: occurrences.didFindWordOccurrences(request, ranges)
        }
      } : nil
  }

  /// テキスト面か検索バーの焦点が変わった（テキスト面はセッション経由でタブから、検索バーはバーから届く）。焦点の行き先は
  /// 同じターンの後で決まるので、次のターンで今の焦点を読み直す。
  func focusDidChange() {
    DispatchQueue.main.async { [weak self] in
      guard let self, let document else { return }
      occurrences.focusDidChange(
        surfaceFocused: window?.firstResponder === document.surface.responder,
        insideFace: focusIsOnTextOrFindBar)
      syncFindState()
    }
  }

  /// 焦点が本文か検索バーにあるか。
  var focusIsOnTextOrFindBar: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    if let document, responder === document.surface.responder { return true }
    if let searchBar, responder.isDescendant(of: searchBar) { return true }
    return false
  }

  /// 検索バーの状態（検索語・入力欄の焦点）を出現の強調へ渡す（同じ文字列を検索中なら選択文字列の出現を出さない）。
  func syncFindState() {
    let fieldFocused =
      searchBar.map { bar in
        (window?.firstResponder as? NSView)?.isDescendant(of: bar) == true
      } ?? false
    occurrences.findStateDidChange(
      needle: searchBar == nil ? nil : search.needle, fieldFocused: fieldFocused)
  }

  /// 検索の一致と語の出現を束ねてミニマップとスクロールバーへ。
  func pushOverviewDecorations() {
    let find = search.overview
    let decorations = OverviewDecorations(
      findMatches: find.matches, currentFindMatch: find.current,
      wordOccurrences: occurrences.wordOccurrences)
    minimap.decorations = decorations
    scrollbar.decorations = decorations
  }

  /// スクロールの状態（縦横の位置・見えている大きさ・行数）が変わればスクロールバーのつまみを見せる——VS Code の
  /// スクロールの状態が変わったときと同じく、スクロールに限らず窓の大きさの変化・改行・横スクロールでも現れる。
  /// 文書を結んだ後の最初の測定では出さない。
  private func noteScrollState() {
    guard let document else { return }
    let viewport = document.surface.viewport
    let state = ScrollState(
      firstLine: document.viewportLines.first, visibleLines: viewport.visibleLines,
      lineCount: document.text.lineCount, hiddenColumns: viewport.hiddenColumns,
      visibleColumns: viewport.visibleColumns)
    defer { lastScrollState = state }
    guard let last = lastScrollState, last != state else { return }
    scrollbar.didScroll()
  }

  /// スクロールの状態（`noteScrollState`）。
  struct ScrollState: Equatable {
    let firstLine: CGFloat
    let visibleLines: CGFloat
    let lineCount: Int
    let hiddenColumns: CGFloat
    let visibleColumns: CGFloat
  }

  /// 本体の上端の影（先頭行が隠れている）とミニマップ左の影（本文が右に続く）。
  func updateShadow() {
    guard let document else { return }
    let viewport = document.surface.viewport
    scrollShadow.showsTop =
      viewport.firstVisible > 0 || viewport.hiddenFraction > 0
    scrollShadow.minimapEdge =
      viewport.clipsRight ? minimap.frame.minX - scrollShadow.frame.minX : nil
  }

  /// ドラッグ中も出入りを受ける（つまみを押したまま本体の外で離せば、つまみが消える）。
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let bodyTracking { removeTrackingArea(bodyTracking) }
    let area = NSTrackingArea(
      rect: bodyRect,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag],
      owner: self)
    addTrackingArea(area)
    bodyTracking = area
  }

  /// 本体の出入りだけを見る——SwiftUI の骨（サイドバー・列の頭）も自分の出入りを上の pane へ流してくる。
  override func mouseEntered(with event: NSEvent) {
    guard event.trackingArea === bodyTracking else { return super.mouseEntered(with: event) }
    scrollbar.hovering = true
  }

  override func mouseExited(with event: NSEvent) {
    guard event.trackingArea === bodyTracking else { return super.mouseExited(with: event) }
    scrollbar.hovering = false
  }
}

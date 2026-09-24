import AppKit
import OrbeEditorCore

/// 文書の「変わった」の扇出と、俯瞰（ミニマップ・スクロールバー・影）と出現の強調への配線。文書側の closure は単一の
/// まま、ここがミニマップ・スクロールバー・影・検索・出現の強調へ配る。検索の一致と語の出現は束ねて
/// （`OverviewDecorations`）ミニマップとスクロールバーへ押す。本体の上のポインタは pane の tracking area が見て、
/// スクロールバーのつまみの見え隠れに使う。
extension EditorPaneView {
  /// 文書の「変わった」を右列・影・検索・出現の強調へ配る（見せている文書だけ）。
  func observe(_ document: EditorDocument, _ on: Bool) {
    document.onViewportChange =
      on
      ? { [weak self] in
        guard let self else { return }
        minimap.refresh()
        scrollbar.refresh()
        noteScrollPosition()
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
      ? { [weak self] change in
        guard let self else { return }
        minimap.textDidChange(change)
        scrollbar.refresh()
        search.textDidChange(change.edit)
        occurrences.textDidChange(change.edit)
      } : nil
  }

  /// テキスト面の焦点が変わった（セッション経由でタブから届く）。焦点の行き先は同じターンの後で決まる（検索バーへ
  /// 移ったなら面の中に居る）。
  func surfaceFocusDidChange(_ focused: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self, document != nil else { return }
      occurrences.focusDidChange(surfaceFocused: focused, insideFace: focusIsInFace)
      syncFindState()
    }
  }

  /// 焦点がエディター面の本文か検索バーにあるか。
  var focusIsInFace: Bool {
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

  /// 縦のスクロール位置が動いたときだけスクロールバーのつまみを見せる（viewport の最初の測定や窓の高さの変化では
  /// 出さない——VS Code はスクロールの出来事で現れる）。
  private func noteScrollPosition() {
    guard let document else { return }
    let first = document.viewportLines.first
    defer { lastFirstLine = first }
    guard let last = lastFirstLine, last != first else { return }
    scrollbar.didScroll()
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

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let bodyTracking { removeTrackingArea(bodyTracking) }
    let area = NSTrackingArea(
      rect: bodyRect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
    addTrackingArea(area)
    bodyTracking = area
  }

  override func mouseEntered(with event: NSEvent) {
    scrollbar.hovering = true
  }

  override func mouseExited(with event: NSEvent) {
    scrollbar.hovering = false
  }
}

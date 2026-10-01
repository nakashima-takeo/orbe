import AppKit
import OrbeEditorCore

/// 文書の「変わった」の扇出と、出現の強調・一致の地への配線。文書側の closure は単一のまま、ここが検索・出現の強調・
/// プロジェクト検索・アウトラインへ配る（裏から届いた問いとアウトラインの結果も）。一致の地は 2 つの出どころ（ファイル内
/// 検索とプロジェクト検索）の和を面へ押す（`pushFindGround`）。見えている範囲が変わったときに検索バーを置き直す。
extension EditorPaneView {
  /// 文書の「変わった」を検索・出現の強調・プロジェクト検索・アウトラインへ配る（見せている文書だけ）。
  func observe(_ document: EditorDocument, _ on: Bool) {
    document.onViewportChange = on ? { [weak self] in self?.placeSearchBar() } : nil
    document.onSelectionChange =
      on
      ? { [weak self] in
        guard let self else { return }
        search.selectionDidChange()
        occurrences.selectionDidChange()
        outline.caretDidMove()
      } : nil
    document.onTextChange =
      on
      ? { [weak self] edits in
        guard let self else { return }
        search.textDidChange(edits)
        occurrences.textDidChange()
        if let document = self.document { projectSearch.documentDidEdit(document, edits) }
      } : nil
    document.onOutlineChange = on ? { [weak self] in self?.outline.outlineDidChange() } : nil
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

  /// 一致の地——ファイル内検索（一致と現在の一致）と、検索パネルが見えている間のプロジェクト検索（焦点の文書のまとまりの
  /// 区間と選んだ一致）の和。どちらも出どころが自分で編集に合わせてずらした区間。
  var findGround: (matches: [NSRange], current: [NSRange]) {
    let find = search.ground
    var matches = find.matches
    var current = find.current.map { [$0] } ?? []
    if showsSearchPanel, let document {
      let project = projectSearch.ground(for: document)
      matches = RangeUnion.union(matches, project.ranges)
      if let selected = project.current { current = RangeUnion.union(current, [selected]) }
    }
    return (matches, current)
  }

  /// 一致の地を面へ押す（状態は持たず、2 つの出どころを読み直す）。どちらかの出どころが変わったとき・文書の切替・
  /// 検索パネルの見え隠れで呼ぶ。
  func pushFindGround() {
    let ground = findGround
    document?.surface.setHighlights(ground.matches, for: .findMatch)
    document?.surface.setHighlights(ground.current, for: .currentFindMatch)
  }
}

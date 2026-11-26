import AppKit
import OrbeEditorCore

/// 文書の「変わった」の扇出と、出現の強調・一致の地への配線。文書側の closure は単一のまま、ここが検索・出現の強調・
/// diff・プロジェクト検索へ配る（裏から届いた問いの結果も）。一致の地は 2 つの出どころ（ファイル内検索とプロジェクト検索）の
/// 和を面へ押す（`pushFindGround`）。
extension EditorPaneView {
  /// 文書の知らせを、本体で編集する文書（`editedDocument`）へ結ぶ。前に結んだ文書と同じなら何もしない。替わったときだけ
  /// 前の文書の知らせを解いて今の文書に結び、プロジェクト検索へ文書を見せたと知らせる。本体を置き換えたときと、diff が面を
  /// 置き直したとき（新しい側の文書が替わりうる）に呼ぶ。
  func bindEditedDocument() {
    let next = editedDocument
    guard next !== boundDocument else { return }
    if let previous = boundDocument { observe(previous, false) }
    boundDocument = next
    guard let next else { return }
    observe(next, true)
    projectSearch.documentDidShow(next)
  }

  /// 文書 `document` の「変わった」を検索・出現の強調・diff・プロジェクト検索へ配る。ファイル内検索と出現の強調は diff の
  /// 本体では相手の文書を持たないので、配っても何もしない。
  private func observe(_ document: EditorDocument, _ on: Bool) {
    document.onViewportChange =
      on
      ? { [weak self] in self?.diff?.viewportDidChange() } : nil
    document.onSelectionChange =
      on
      ? { [weak self, unowned document] in
        guard let self else { return }
        search.selectionDidChange()
        occurrences.selectionDidChange()
        searchPlacedSelectionDidChange(in: document)
      } : nil
    document.onTextChange =
      on
      ? { [weak self, unowned document] edits in
        guard let self else { return }
        search.textDidChange(edits)
        occurrences.textDidChange()
        diff?.documentTextDidChange()
        projectSearch.documentDidEdit(document, edits)
      } : nil
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

  /// テキスト面かファイル内検索の欄の焦点が変わった（テキスト面はセッション経由で連から、欄は欄の状態から届く）。焦点の行き先は
  /// 同じターンの後で決まるので、次のターンで今の焦点を読み直す。
  func focusDidChange() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let diff, let responder = window?.firstResponder as? NSView {
        let surfaces = diffSurfaces(diff)
        if let index = surfaces.firstIndex(where: { $0.responder === responder }) {
          diffFocusesLeft = surfaces.count == 2 && index == 0
        }
      }
      guard let document else { return }
      occurrences.focusDidChange(
        surfaceFocused: window?.firstResponder === document.surface.responder,
        insideFace: focusIsOnTextOrFindField)
      syncFindState()
    }
  }

  /// 焦点が本文かファイル内検索の欄にあるか。
  var focusIsOnTextOrFindField: Bool {
    if findField.isFocused { return true }
    guard let document, let responder = window?.firstResponder as? NSView else { return false }
    return responder === document.surface.responder
  }

  /// ファイル内検索の欄の状態（検索語・欄の焦点）を出現の強調へ渡す（同じ文字列を検索中なら選択文字列の出現を出さない）。
  func syncFindState() {
    occurrences.findStateDidChange(
      needle: findField.model == nil ? nil : search.needle, fieldFocused: findField.isFocused)
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

import AppKit
import OrbeEditorCore

/// ファイル内検索。バーはスクロールバック検索と同じ部品（`SearchBar`）で、本文の右上（ミニマップの左）に浮く。
/// 検索の状態は `EditorSearch`、規則は Core。`SurfaceView+Search` と同形。
extension EditorPaneView {
  /// 検索バーを出す。種があれば needle に入れて即検索する——1 行以内の非空の選択、選択が空ならキャレットの語（VS Code の
  /// seedSearchStringFromSelection の既定）。選択は動かさない。種は検索へ直接渡し、バーには表示として写す（初回描画前の
  /// 値では SwiftUI の `onChange` が走らず、描画後なら走るが同じ needle なので検索は何もしない）。バーが既にあれば、
  /// 種で needle を取り直し（種が無ければ前の needle のまま）、入力欄に焦点を入れて全選択する（VS Code と同じ）。
  /// 文書が無ければ何も起きない。
  func showSearch() {
    guard let document else { return }
    let seed = searchSeed(document)
    if let bar = searchBar {
      if let seed {
        search.seed(seed)
        bar.needle = seed
      }
      bar.focusField()
      bar.selectNeedle()
      return
    }
    let bar = SearchBar(
      translucency: translucency ?? ChromeTranslucency(), localization: localization)
    bar.showsUnknownPosition = true
    bar.onNeedleChange = { [weak self] needle in self?.search.setNeedle(needle) }
    bar.onFocusChange = { [weak self] in self?.focusDidChange() }
    bar.onNext = { [weak self] in self?.search.next() }
    bar.onPrev = { [weak self] in self?.search.previous() }
    bar.onClose = { [weak self] in self?.closeSearch() }
    addSubview(bar)
    let trailing = bar.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(rightColumnWidth + Theme.Space.beat))
    NSLayoutConstraint.activate([
      trailing,
      bar.topAnchor.constraint(equalTo: topAnchor, constant: headerHeight + Theme.Space.beat),
    ])
    searchBar = bar
    searchBarTrailing = trailing
    syncFindState()
    if let seed {
      bar.needle = seed
      search.seed(seed)
    }
    bar.focusField()
  }

  /// 検索の種——1 行以内の非空の選択、選択が空ならキャレットの語。
  private func searchSeed(_ document: EditorDocument) -> String? {
    let selection = document.surface.selectedRange
    guard selection.length > 0 else {
      return document.word(at: selection).map(document.surface.substring(in:))
    }
    let seed = document.surface.substring(in: selection)
    return seed.contains(where: \.isNewline) ? nil : seed
  }

  /// 本文で Esc（変換中でない）。バーがあれば閉じる（VS Code と同じ）。無ければ上の responder へ。
  override func cancelOperation(_ sender: Any?) {
    guard searchBar != nil else {
      nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
      return
    }
    closeSearch()
  }

  /// バーを閉じる。一致の地は消え、選択はそのまま残る。焦点がバーにあればテキスト面へ戻す。
  func closeSearch() {
    guard let bar = searchBar else { return }
    let focused = (window?.firstResponder as? NSView)?.isDescendant(of: bar) == true
    search.close()
    bar.removeFromSuperview()
    searchBar = nil
    searchBarTrailing = nil
    syncFindState()
    if focused { window?.makeFirstResponder(focusTarget) }
  }
}

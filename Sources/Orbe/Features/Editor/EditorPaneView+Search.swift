import AppKit
import OrbeEditorCore

/// ファイル内検索。バーはスクロールバック検索と同じ部品（`SearchBar`）で、本文の右上（ミニマップの左）に浮く。
/// 検索の状態は `EditorSearch`、規則は Core。`SurfaceView+Search` と同形。
extension EditorPaneView {
  /// 検索バーを出す（既にあれば再フォーカス）。種があれば needle に入れて即検索する——1 行以内の非空の選択、選択が
  /// 空ならキャレットの語（VS Code の seedSearchStringFromSelection の既定）。種は検索へ直接渡し、バーには表示として写す
  /// （SwiftUI の `onChange` は初回描画前の値では走らない）。文書が無ければ何も起きない。
  func showSearch() {
    guard let document else { return }
    if let bar = searchBar {
      bar.focusField()
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
    if let seed = searchSeed(document) {
      bar.needle = seed
      search.setNeedle(seed)
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

import AppKit

/// スクロールバック検索。検索本体は libghostty 側にあり、本 extension は
/// SearchBar の表示と search 系 binding action への橋渡し・件数表示の更新を担う。
extension SurfaceView {
  /// 検索バーを表示（既出なら再フォーカス）。入力・次/前・終了を surface の
  /// search 系 binding action へ橋渡しする（検索本体は libghostty 側）。
  func showSearch() {
    if let bar = searchBar {
      bar.focusField()
      return
    }
    let bar = SearchBar(
      translucency: chromeTranslucency ?? ChromeTranslucency(),
      localization: localization ?? LocalizationStore(language: .systemDefault))
    bar.onNeedleChange = { [weak self] needle in
      // 件数は通知が来るまで未確定に戻す。空文字は libghostty 側で検索停止＝件数 0。
      self?.searchSelected = nil
      self?.searchTotal = nil
      self?.surfaceBinding("search:\(needle)")
    }
    bar.onNext = { [weak self] in self?.surfaceBinding("navigate_search:next") }
    bar.onPrev = { [weak self] in self?.surfaceBinding("navigate_search:previous") }
    bar.onClose = { [weak self] in self?.closeSearch() }
    addSubview(bar)
    NSLayoutConstraint.activate([
      bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      bar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
    ])
    searchBar = bar
    bar.focusField()
  }

  private func closeSearch() {
    surfaceBinding("end_search")
    searchBar?.removeFromSuperview()
    searchBar = nil
    searchSelected = nil
    searchTotal = nil
    window?.makeFirstResponder(self)
  }

  /// libghostty の SEARCH_TOTAL / SEARCH_SELECTED 通知を受けて件数表示を更新する。
  func updateSearchTotal(_ total: Int?) {
    searchTotal = total
    searchBar?.updateCount(selected: searchSelected, total: searchTotal)
  }
  func updateSearchSelected(_ selected: Int?) {
    searchSelected = selected
    searchBar?.updateCount(selected: searchSelected, total: searchTotal)
  }
}

import AppKit
import OrbeEditorCore

/// ファイル内検索。欄は上のバーの Files の中ほど（`EditorBarFindField`）で、出している間の欄の状態は面ごとの持ち主
/// （`findField`）が持つ。欄の状態の型と件数の規則は、端末のスクロールバック検索のバーと共有する。検索の状態は
/// `EditorSearch`、規則は Core。
extension EditorPaneView {
  /// 検索の状態の知らせを結ぶ——件数は欄へ、一致の変化は一致の地へ、検索語の変化は検索の状態の写しへ。
  func wireSearch() {
    search.onCountChange = { [weak self] selected, total, limited in
      self?.findField.model?.updateCount(selected: selected, total: total, limited: limited)
    }
    search.onMatchesChange = { [weak self] in self?.pushFindGround() }
    search.onNeedleChange = { [weak self] in self?.syncFindState() }
  }

  /// 欄を出す。種があれば検索語に入れて即検索する——1 行以内の非空の選択、選択が空ならキャレットの語（VS Code の
  /// seedSearchStringFromSelection の既定）。選択は動かさない。種は検索へ直接渡し、欄には表示として写す（初回描画前の
  /// 値では SwiftUI の `onChange` が走らず、描画後なら走るが同じ検索語なので検索は何もしない）。欄が既にあれば、
  /// 種で検索語を取り直し（種が無ければ前の検索語のまま）、欄にフォーカスを入れて全選択する（VS Code と同じ）。
  /// 文書が無ければ何も起きない。
  func showSearch() {
    guard let document else { return }
    let seed = searchSeed(document)
    if let field = findField.model {
      if let seed {
        search.seed(seed)
        field.needle = seed
      }
      findField.requestFocus()
      return
    }
    let field = findField.open()
    field.showsUnknownPosition = true
    field.onNeedleChange = { [weak self] needle in self?.search.setNeedle(needle) }
    field.onFocusChange = { [weak self] in self?.focusDidChange() }
    field.onNext = { [weak self] in self?.search.next() }
    field.onPrev = { [weak self] in self?.search.previous() }
    field.onClose = { [weak self] in self?.closeSearch() }
    syncFindState()
    if let seed {
      field.needle = seed
      search.seed(seed)
    }
    findField.requestFocus()
  }

  /// 検索の種——1 行以内の非空の選択、選択が空ならキャレットの語。
  private func searchSeed(_ document: EditorDocument) -> String? {
    let selection = document.surface.selectedRange
    guard selection.length > 0 else {
      return document.word(at: selection).map(document.text.substring)
    }
    let seed = document.text.substring(selection)
    return seed.contains(where: \.isNewline) ? nil : seed
  }

  /// 欄を閉じる。一致の地は消え、選択はそのまま残る。フォーカスが欄にあれば、欄を消す前にテキスト面へ移す（フォーカスを
  /// 持ったまま消すと、AppKit がフォーカスを窓へ落とす）。
  func closeSearch() {
    guard findField.model != nil else { return }
    if findField.isFocused { window?.makeFirstResponder(focusTarget) }
    search.close()
    findField.close()
    syncFindState()
  }
}

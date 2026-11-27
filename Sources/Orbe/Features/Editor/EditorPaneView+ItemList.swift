import AppKit

/// 一覧の器の置き場——開いたら器の host と行の列をバーより下の最前面に出して置き、行の列へフォーカスを移す。閉じたら隠し、
/// きっかけが求めれば本体の行き先へフォーカスを戻す。位置は上のバーの今の項目のボタンの左下。
extension EditorPaneView {
  func wireItemList() {
    itemListHost.isHidden = true
    itemList.list.isHidden = true
    itemList.onOpen = { [weak self] in self?.itemListDidOpen() }
    shell.toggleItemList = { [weak self] in self?.toggleItemList() }
    shell.keepOpen = { [weak self] in self?.keepCurrentOpen() }
    observeSearchFocus()
    shell.itemButtonFrameDidChange = { [weak self] frame in
      guard let self, frame != itemButtonFrame else { return }
      itemButtonFrame = frame
      if itemList.isOpen { needsLayout = true }
    }
    itemList.onClose = { [weak self] dismissal in self?.itemListDidClose(dismissal) }
    itemList.onResize = { [weak self] in self?.needsLayout = true }
  }

  /// フォーカスが一覧の器の行の列にあるか。
  var focusIsInItemList: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder.isDescendant(of: itemList.list)
  }

  /// 器を出して置き、行の列へフォーカスを移す。ポップアップが開いていれば閉じる（同時に 1 つだけ開く）。
  private func itemListDidOpen() {
    popup.close(.otherOpened)
    endListFocusHold()
    let views: [NSView] = [itemListHost, itemList.list]
    if !belowBar.subviews.suffix(2).elementsEqual(views, by: ===) {
      for view in views {
        view.removeFromSuperview()
        view.autoresizingMask = []
        belowBar.addSubview(view)
      }
    }
    for view in views { view.isHidden = false }
    needsLayout = true
    layoutSubtreeIfNeeded()
    window?.makeFirstResponder(itemList.list.list)
  }

  /// 器を隠す。フォーカスを戻すきっかけなら、隠す前に本体の行き先へ移す。フォーカスが一覧の外へ移って閉じたときは、
  /// first responder が替わる途中なので、行の列を隠すのは次のターンにする（フォーカスを持つ view を隠すと、AppKit が
  /// その場でフォーカスを動かし、移動が入れ子になる）。
  private func itemListDidClose(_ dismissal: EditorDismissal) {
    containerDidClose(dismissal)
    if dismissal.returnsFocus { focusEditor() }
    itemListHost.isHidden = true
    guard focusIsInItemList else {
      itemList.list.isHidden = true
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, !itemList.isOpen else { return }
      itemList.list.isHidden = true
    }
  }

  /// 一覧の矩形——上端は上のバーの下端、左端は今の項目のボタンの左端。幅は器の幅（面に足りなければ面の幅）で、右端が面から
  /// はみ出すなら左へ寄せる。高さは行の数に合わせ、上限はバーより下の高さから下の余白を引いた高さ（越えた分は行の列の
  /// 中でスクロールする）。
  var itemListRect: NSRect {
    let top = Theme.Layout.editorBar
    let width = min(Theme.Layout.editorItemListWidth, bounds.width)
    let left = min(max(0, itemButtonFrame?.minX ?? 0), bounds.width - width)
    let pad = Theme.Layout.editorItemListPad
    let rows = CGFloat(itemList.rowCount) * Theme.Layout.editorItemListRow
    let ceiling = max(0, bounds.height - top - Theme.Layout.editorItemListBottom)
    let height = min(rows + pad * 2 + Theme.Layout.editorItemListFooter, ceiling)
    return NSRect(x: left, y: top, width: width, height: height)
  }

  /// 器の host と行の列を置く（`layout()` の最後。閉じている間は置かない）。
  func layoutItemList() {
    guard itemList.isOpen else { return }
    let rect = itemListRect
    let margin = EditorItemListRoot.margin
    itemListHost.frame = rect.insetBy(dx: -margin, dy: -margin)
    let pad = Theme.Layout.editorItemListPad
    itemList.list.frame = NSRect(
      x: rect.minX + pad, y: rect.minY + pad, width: max(0, rect.width - pad * 2),
      height: max(0, rect.height - pad * 2 - Theme.Layout.editorItemListFooter))
  }

  /// 窓の押下 `event` が、一覧の器（行の列か、地と下の案内）か、今の項目のボタンの上か。
  func pressIsOnItemList(_ event: NSEvent) -> Bool {
    if let view = window?.contentView?.hitTest(event.locationInWindow),
      view.isDescendant(of: itemList.list) || view.isDescendant(of: itemListHost)
    {
      return true
    }
    let point = convert(event.locationInWindow, from: nil)
    return itemButtonFrame?.contains(point) == true
  }
}

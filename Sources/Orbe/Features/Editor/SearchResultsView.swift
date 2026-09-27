import AppKit

/// 検索結果の列（スクロールの器）。pane が 1 つ持ち、検索パネルが隠れている間も捨てない——出し直すたびに行の view を
/// 作り直さない。検索パネル（SwiftUI）はこれを借りて載せ、読む値（行の版・選択・焦点の要求・絵文字の字体）を `update` で渡す。
final class SearchResultsView: NSScrollView {
  let list: SearchResultsListView
  private var rowsVersion: Int?
  /// 最後に写した選択。選択が変わったときだけ、その行が見えるまで送る（列が出た時点の選択へは送らない）。
  private var selection: ProjectSearch.RowID?

  init(search: ProjectSearch) {
    list = SearchResultsListView(search: search)
    super.init(frame: .zero)
    documentView = list
    drawsBackground = false
    borderType = .noBorder
    hasVerticalScroller = true
    hasHorizontalScroller = false
    autohidesScrollers = true
    automaticallyAdjustsContentInsets = false
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  func update(
    rowsVersion: Int, selection: ProjectSearch.RowID?, emoji: NSFont?, wantsFocus: Bool
  ) {
    if rowsVersion != self.rowsVersion || emoji !== list.emoji {
      self.rowsVersion = rowsVersion
      list.emoji = emoji
      list.reloadRows()
    }
    list.selectedRow = selection.flatMap { list.search.rowIndex(of: $0) }
    if selection != self.selection {
      self.selection = selection
      if let row = list.selectedRow { list.scrollRowToVisible(row) }
    }
    if wantsFocus {
      // 焦点を移すと入力欄の SwiftUI の焦点も変わるので、この更新の外で当てる。
      DispatchQueue.main.async { [weak self] in self?.list.applyFocusRequest() }
    }
  }

  override func tile() {
    super.tile()
    list.fitWidth(to: contentSize.width)
    list.layoutRows()
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    list.layoutRows()
  }
}

/// 検索結果の平らな行を並べる列。行は最大で約 2 万になるので、見えている行の数＋1 本の行の view だけを持ち、行 r を
/// 枠 r mod 本数 に割り当てて使い回す——1 行ぶん送っても描き直すのは入れ替わった 1 行で、行の数が変わっても列の高さを
/// 変えるだけ（行ごとの仕事をしない）。行の高さは 1 つ。行は `ProjectSearch` から番号で引いて描くだけで、選択・開閉・
/// 開くは model の操作を呼ぶ（列は自分で選択を動かさない）。
///
/// キー: ↑↓ は選択だけを動かし（開かない）、← → は折りたたみと親子の移動、Enter は開いてテキスト面へ、Esc は止めるか選択を
/// 外す。Home / End・PageUp / PageDown は送るだけ。一致のシングルクリックは選んで開き（焦点は列に残る）、ダブルクリックは
/// 開いてテキスト面へ。VoiceOver には AX のリスト（行の総数と、見えている行・選択中の行）として見せる。
final class SearchResultsListView: NSView {
  let search: ProjectSearch
  var emoji: NSFont?
  private let rowHeight = Theme.Layout.editorSearchRow
  private(set) var rowCount = 0
  private var slots: [SearchResultRowView] = []

  /// 選んでいる行の番号（model の選択を写したもの）。
  var selectedRow: Int? {
    didSet {
      guard selectedRow != oldValue else { return }
      for slot in slots { slot.isSelected = slot.row != nil && slot.row == selectedRow }
      NSAccessibility.post(element: self, notification: .selectedRowsChanged)
    }
  }

  init(search: ProjectSearch) {
    self.search = search
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.list)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    applyFocusRequest()
    // 列が出た更新そのものには載せず、次の周回で済ませる。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      SearchResultRowView.prepare(for: effectiveAppearance)
    }
  }

  // MARK: - 行

  /// 行の数と中身を読み直す。見えている行の view は捨てずに中身だけを差し替える（中身が同じ行は描き直さない）。
  func reloadRows() {
    rowCount = search.rowCount
    setFrameSize(NSSize(width: frame.width, height: CGFloat(rowCount) * rowHeight))
    layoutRows()
  }

  func fitWidth(to width: CGFloat) {
    guard width != frame.width else { return }
    setFrameSize(NSSize(width: width, height: frame.height))
    for slot in slots { slot.setFrameSize(NSSize(width: width, height: rowHeight)) }
  }

  /// 見えている行に枠を割り当てて描かせる（行が見えなくなった枠は隠す）。
  func layoutRows() {
    let visible = visibleRect
    let capacity = Int((max(visible.height, rowHeight) / rowHeight).rounded(.up)) + 1
    while slots.count < capacity {
      let slot = SearchResultRowView(
        frame: NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight))
      addSubview(slot)
      slots.append(slot)
    }
    let first = max(0, Int(visible.minY / rowHeight))
    let last = min(rowCount, Int((visible.maxY / rowHeight).rounded(.up)))
    var shown = Set<Int>()
    for row in first..<max(first, last) {
      let index = row % slots.count
      shown.insert(index)
      let slot = slots[index]
      if slot.row != row {
        slot.row = row
        slot.setFrameOrigin(NSPoint(x: 0, y: CGFloat(row) * rowHeight))
      }
      slot.show(search.row(at: row), emoji: emoji)
      slot.isSelected = row == selectedRow
      slot.isHidden = false
    }
    for (index, slot) in slots.enumerated() where !shown.contains(index) {
      slot.isHidden = true
      slot.row = nil
      slot.isSelected = false
    }
  }

  func scrollRowToVisible(_ row: Int) {
    scrollToVisible(NSRect(x: 0, y: CGFloat(row) * rowHeight, width: 1, height: rowHeight))
  }

  private func row(at point: NSPoint) -> Int? {
    let row = Int(point.y / rowHeight)
    return point.y >= 0 && row < rowCount ? row : nil
  }

  // MARK: - 焦点

  /// 結果の列へ焦点を入れる要求を当てる（窓に載っていなければ、載ったときにもう一度呼ばれる）。
  func applyFocusRequest() {
    guard search.focusRequest == .results, let window else { return }
    window.makeFirstResponder(self)
    search.focusRequestDidApply()
  }

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    search.focusDidChange(.results, focused: true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    search.focusDidChange(.results, focused: false)
    return true
  }

  // MARK: - マウス

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return }
    let id = search.row(at: row).id
    if event.clickCount >= 2 {
      search.doubleClick(id)
    } else {
      search.click(id)
    }
  }

  // MARK: - キー

  override func keyDown(with event: NSEvent) {
    interpretKeyEvents([event])
  }

  override func moveUp(_ sender: Any?) { search.moveSelection(by: -1) }
  override func moveDown(_ sender: Any?) { search.moveSelection(by: 1) }
  override func moveUpAndModifySelection(_ sender: Any?) { search.moveSelection(by: -1) }
  override func moveDownAndModifySelection(_ sender: Any?) { search.moveSelection(by: 1) }
  override func moveLeft(_ sender: Any?) { search.moveLeft() }
  override func moveRight(_ sender: Any?) { search.moveRight() }
  override func insertNewline(_ sender: Any?) { search.activateSelection() }
  override func cancelOperation(_ sender: Any?) { search.escapeInResults() }

  override func scrollToBeginningOfDocument(_ sender: Any?) {
    scroll(NSPoint(x: 0, y: 0))
  }

  override func scrollToEndOfDocument(_ sender: Any?) {
    scroll(NSPoint(x: 0, y: max(0, bounds.height - visibleRect.height)))
  }

  override func scrollPageUp(_ sender: Any?) { scrollPage(by: -1) }
  override func scrollPageDown(_ sender: Any?) { scrollPage(by: 1) }
  override func pageUp(_ sender: Any?) { scrollPage(by: -1) }
  override func pageDown(_ sender: Any?) { scrollPage(by: 1) }

  /// 1 画面ぶん送る（1 行ぶん重ねて、読んでいた行を見失わない）。
  private func scrollPage(by direction: CGFloat) {
    let step = max(rowHeight, visibleRect.height - rowHeight)
    let top = min(
      max(0, visibleRect.minY + step * direction), max(0, bounds.height - visibleRect.height))
    scroll(NSPoint(x: 0, y: top))
  }

  // MARK: - アクセシビリティ

  override func accessibilityRows() -> [Any]? {
    slots.filter { $0.row != nil }.sorted { $0.row! < $1.row! }
  }

  override func accessibilityChildren() -> [Any]? { accessibilityRows() }

  override func accessibilityVisibleRows() -> [Any]? { accessibilityRows() }

  override func accessibilitySelectedRows() -> [Any]? {
    slots.filter(\.isSelected)
  }

  override func setAccessibilitySelectedRows(_ rows: [Any]?) {
    guard let row = (rows?.first as? SearchResultRowView)?.row else { return }
    search.select(search.row(at: row).id)
  }

  override func accessibilityRowCount() -> Int { rowCount }
}

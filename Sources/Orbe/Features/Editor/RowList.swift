import AppKit

/// 行の列（`RowList`）の源。行の数・行の中身・操作の意味を答える。列は見えている行の枠（行の view）だけを持ち、行を
/// 番号で源に問うて描かせる。選択は源（model）が持ち、列は操作を渡すだけで自分では動かさない。
@MainActor
protocol RowListSource: AnyObject {
  associatedtype RowView: ListRowView
  /// 選択の同一性（行の番号がずれても同じ選択を指す値）。
  associatedtype Selection: Hashable

  /// 行の数。列は行を問う上限にもこの今の値を使う（行の数は列が読み直すより先に変わりうる）。
  var rowCount: Int { get }
  /// 枠を 1 つ作る。列は見えている行の数＋1 本まで作って使い回す。
  func makeRowView() -> RowView
  /// 枠 `view` に行 `row` の中身を写す。列は並べるたび（送るたびを含む）に見えている全行について呼ぶので、中身が
  /// 前と同じなら描き直さない。
  /// `emoji` は chrome の絵文字の字体（ユーザー由来の名前に充てる）。
  func show(_ row: Int, in view: RowView, emoji: NSFont?)
  /// 選択 `selection` の行の番号（今の行に無ければ nil）。
  func row(of selection: Selection) -> Int?
  /// 最初の行を描く前に 1 度だけ要る準備（字体の読み込み・初回の字組み・色の解決）。列が窓に載った次の周回で呼ぶ。
  func prepareRows(for appearance: NSAppearance)

  /// 列へ焦点を入れる要求があるか（列が窓に載ったとき・`update` で求められたときに見る）。
  var wantsFocus: Bool { get }
  /// 列が焦点の要求を当てた。
  func focusRequestDidApply()
  /// 列の焦点が入った・抜けた。
  func focusDidChange(_ focused: Bool)

  /// 列に焦点がある間の打鍵を、キーとして解く前に源が引き取って処理する。引き取ったら true（列はその打鍵に何もしない）。
  func takeTyping(_ event: NSEvent) -> Bool
  /// キーの操作。扱ったら true。扱わなければ、Home / End・PageUp / PageDown は列が送るだけにし、Space は次の
  /// responder へ回す。
  func perform(_ key: RowListKey) -> Bool
  /// 行 `row` のシングルクリック（`x` は行の中の横の位置）。
  func click(_ row: Int, x: CGFloat)
  /// 行 `row` のダブルクリック（`x` は行の中の横の位置）。
  func doubleClick(_ row: Int, x: CGFloat)
  /// VoiceOver がリストの行 `row` を選んだ。
  func select(_ row: Int)
}

/// 列が源へ渡すキーの操作。
enum RowListKey {
  /// ↑↓（⇧つきも同じ）。
  case up, down
  case left, right
  case enter, escape, space
  case home, end, pageUp, pageDown
}

/// 行を見せる送り方。
enum RowListReveal {
  /// 見えていなければ、見えるところまで最小限だけ送る。
  case nearest
  /// 見えていなければ、列の縦の中央へ寄せる。
  case center
}

/// 行の列のスクロールの器。持ち主（pane）が持ち続け、載せる SwiftUI が隠れている間も捨てない——出し直すたびに行の
/// view を作り直さない。読む値（行の版・選択・焦点の要求・絵文字の字体）は `update` で受ける。
final class RowList<Source: RowListSource>: NSScrollView {
  let list: RowListView<Source>
  private var rowsVersion: Int?
  /// 最後に写した選択。選択が変わったときだけ、その行を見せる（行の番号がずれただけ・列が出ただけでは送らない）。
  private var selection: Source.Selection?
  /// 大きさが決まる前に選択が変わったときの見せ方。大きさの無い列で送ると、後で大きさが付いても送った位置が残るので、
  /// 大きさが付いた最初の `tile` で当てる。
  private var pendingReveal: (selection: Source.Selection, how: RowListReveal)?

  init(source: Source, rowHeight: CGFloat) {
    list = RowListView(source: source, rowHeight: rowHeight)
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

  /// 行の版が変わった（か絵文字の字体が変わった）ときだけ行を読み直し、選択の行を写す。選択が変わったときだけ、
  /// その行を `reveal` のやり方で見せる。
  func update(
    rowsVersion: Int, selection: Source.Selection?, reveal: RowListReveal, emoji: NSFont?,
    wantsFocus: Bool
  ) {
    if rowsVersion != self.rowsVersion || emoji !== list.emoji {
      self.rowsVersion = rowsVersion
      list.emoji = emoji
      list.reloadRows()
    }
    list.selectedRow = selection.flatMap { list.source.row(of: $0) }
    if selection != self.selection {
      self.selection = selection
      pendingReveal = nil
      if let selection, let row = list.selectedRow {
        if contentSize.height > 0 {
          list.reveal(row, reveal)
        } else {
          pendingReveal = (selection, reveal)
        }
      }
    }
    if wantsFocus {
      // 焦点を移すと載せている SwiftUI の焦点も変わるので、この更新の外で当てる。
      DispatchQueue.main.async { [weak self] in self?.list.applyFocusRequest() }
    }
  }

  override func tile() {
    super.tile()
    list.fitWidth(to: contentSize.width)
    list.layoutRows()
    guard contentSize.height > 0, let pending = pendingReveal else { return }
    pendingReveal = nil
    if let row = list.source.row(of: pending.selection) { list.reveal(row, pending.how) }
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    list.layoutRows()
  }
}

/// 行を並べる列（`RowList` の文書）。行は数万になりうるので、見えている行の数＋1 本の枠だけを持ち、行 r を枠
/// r mod 本数 に割り当てて使い回す——送って描き直すのは新しく見えた行だけで、行の数が変わっても列の高さを変えるだけ
/// （行ごとの仕事をしない）。行の高さは 1 つ。
///
/// キーは源の操作へ渡す（`RowListKey`）。Home / End・PageUp / PageDown は源が扱わなければ送るだけ。文字の打鍵は解かない
/// ——解く前に源へ渡し、源が引き取れば解かない。押すと焦点を取り、行の番号と行の中の横の位置を源へ渡す。VoiceOver には AX の
/// リスト（行の総数と、見えている行・選択の行）として見せる。
final class RowListView<Source: RowListSource>: NSView {
  let source: Source
  let rowHeight: CGFloat
  var emoji: NSFont?
  /// 列の高さを決めた行の数（`reloadRows` で源から写す）。行を問う上限は源の今の行の数。
  private(set) var rowCount = 0
  private var slots: [Source.RowView] = []

  /// 選んでいる行の番号（源の選択を写したもの）。
  var selectedRow: Int? {
    didSet {
      guard selectedRow != oldValue else { return }
      for slot in slots { slot.isSelected = slot.row != nil && slot.row == selectedRow }
      NSAccessibility.post(element: self, notification: .selectedRowsChanged)
    }
  }

  init(source: Source, rowHeight: CGFloat) {
    self.source = source
    self.rowHeight = rowHeight
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
      source.prepareRows(for: effectiveAppearance)
    }
  }

  // MARK: - 行

  /// 行の数と中身を読み直す。見えている行の枠は捨てずに中身だけを差し替える。
  func reloadRows() {
    rowCount = source.rowCount
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
      let slot = source.makeRowView()
      slot.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight)
      addSubview(slot)
      slots.append(slot)
    }
    let first = max(0, Int(visible.minY / rowHeight))
    let last = min(source.rowCount, Int((visible.maxY / rowHeight).rounded(.up)))
    var shown = Set<Int>()
    for row in first..<max(first, last) {
      let index = row % slots.count
      shown.insert(index)
      let slot = slots[index]
      if slot.row != row {
        slot.row = row
        slot.setFrameOrigin(NSPoint(x: 0, y: CGFloat(row) * rowHeight))
      }
      source.show(row, in: slot, emoji: emoji)
      slot.isSelected = row == selectedRow
      slot.isHidden = false
    }
    for (index, slot) in slots.enumerated() where !shown.contains(index) {
      slot.isHidden = true
      slot.row = nil
      slot.isSelected = false
    }
  }

  /// 行 `row` を `how` のやり方で見せる（見えていれば動かさない）。
  func reveal(_ row: Int, _ how: RowListReveal) {
    switch how {
    case .nearest: scrollRowToVisible(row)
    case .center: scrollRowToCenter(row)
    }
  }

  /// 見えていなければ、見えるところまで最小限だけ送る。
  func scrollRowToVisible(_ row: Int) {
    scrollToVisible(rect(ofRow: row))
  }

  /// 見えていなければ、列の縦の中央へ寄せる（端では寄せ切らない）。
  func scrollRowToCenter(_ row: Int) {
    let rect = rect(ofRow: row)
    let visible = visibleRect
    guard visible.minY > rect.minY || visible.maxY < rect.maxY else { return }
    let top = min(
      max(0, rect.midY - visible.height / 2), max(0, bounds.height - visible.height))
    scroll(NSPoint(x: 0, y: top))
  }

  private func rect(ofRow row: Int) -> NSRect {
    NSRect(x: 0, y: CGFloat(row) * rowHeight, width: 1, height: rowHeight)
  }

  private func row(at point: NSPoint) -> Int? {
    let row = Int(point.y / rowHeight)
    return point.y >= 0 && row < source.rowCount ? row : nil
  }

  // MARK: - 焦点

  /// 列へ焦点を入れる要求を当てる（窓に載っていなければ、載ったときにもう一度呼ばれる）。
  func applyFocusRequest() {
    guard source.wantsFocus, let window else { return }
    window.makeFirstResponder(self)
    source.focusRequestDidApply()
  }

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    source.focusDidChange(true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    source.focusDidChange(false)
    return true
  }

  // MARK: - マウス

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    guard let row = row(at: point) else { return }
    if event.clickCount >= 2 {
      source.doubleClick(row, x: point.x)
    } else {
      source.click(row, x: point.x)
    }
  }

  // MARK: - キー

  override func keyDown(with event: NSEvent) {
    guard !source.takeTyping(event) else { return }
    interpretKeyEvents([event])
  }

  override func moveUp(_ sender: Any?) { _ = source.perform(.up) }
  override func moveDown(_ sender: Any?) { _ = source.perform(.down) }
  override func moveUpAndModifySelection(_ sender: Any?) { _ = source.perform(.up) }
  override func moveDownAndModifySelection(_ sender: Any?) { _ = source.perform(.down) }
  override func moveLeft(_ sender: Any?) { _ = source.perform(.left) }
  override func moveRight(_ sender: Any?) { _ = source.perform(.right) }
  override func insertNewline(_ sender: Any?) { _ = source.perform(.enter) }
  override func cancelOperation(_ sender: Any?) { _ = source.perform(.escape) }

  /// Space は文字として届く。
  override func insertText(_ insertString: Any) {
    if insertString as? String == " ", source.perform(.space) { return }
    super.insertText(insertString)
  }

  override func scrollToBeginningOfDocument(_ sender: Any?) {
    guard !source.perform(.home) else { return }
    scroll(NSPoint(x: 0, y: 0))
  }

  override func scrollToEndOfDocument(_ sender: Any?) {
    guard !source.perform(.end) else { return }
    scroll(NSPoint(x: 0, y: max(0, bounds.height - visibleRect.height)))
  }

  override func scrollPageUp(_ sender: Any?) { page(.pageUp) }
  override func scrollPageDown(_ sender: Any?) { page(.pageDown) }
  override func pageUp(_ sender: Any?) { page(.pageUp) }
  override func pageDown(_ sender: Any?) { page(.pageDown) }

  /// 源が扱わなければ 1 画面ぶん送る（1 行ぶん重ねて、読んでいた行を見失わない）。
  private func page(_ key: RowListKey) {
    guard !source.perform(key) else { return }
    let step = max(rowHeight, visibleRect.height - rowHeight) * (key == .pageUp ? -1 : 1)
    let top = min(
      max(0, visibleRect.minY + step), max(0, bounds.height - visibleRect.height))
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
    guard let row = (rows?.first as? ListRowView)?.row else { return }
    source.select(row)
  }

  override func accessibilityRowCount() -> Int { source.rowCount }
}

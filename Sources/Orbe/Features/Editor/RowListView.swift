import AppKit

/// 行を並べる列（`RowList` の文書）。行は数万になりうるので、見えている行の数＋1 本の枠だけを持ち、行 r を枠
/// r mod 本数 に割り当てて使い回す——送って描き直すのは新しく見えた行だけで、行の数が変わっても列の高さを変えるだけ
/// （行ごとの仕事をしない）。行の高さは源の区間の表で決まり、位置 ↔ 行は区間の表を二分探索で引く。最後の行の下に行 1 つ分の
/// 空きを持つ——末尾まで送っても最後の行が下端に付かない（VS Code の一覧と同じ）。空きは文書の内側なので、ホイール・つまみ・
/// End のどれでも届き、押しても行は無い。
///
/// キーは源の操作へ渡す（`RowListKey`）。Home / End・PageUp / PageDown は列が送るだけ。押すと焦点を取り、行の番号を源へ
/// 渡す——行の中の部品の上なら、行のクリックではなく部品の押下として渡す。ポインタの下の行には行の中の位置を写す（hover と、
/// 部品の説明のツールチップ）。VoiceOver には AX のリスト（行の総数と、見えている行・選択の行）として見せる。
///
/// 部品の押下に源が錨を返せば、留める行の上端を押した行の窓の中の高さに合わせ続け、押し続けの守りを張る
/// （→ `RowListAnchor`・`RowListPressGuard`）。上へは原点が 0 に着くまでしか送らず、下へ送りきれなければ文書の下に一時の
/// 空きを足して収める。外せば空きを取り、原点を範囲に収める。
final class RowListView<Source: RowListSource>: NSView {
  let source: Source
  let rowHeight: CGFloat
  var emoji: NSFont?
  /// 描いている行の組（`reloadRows` で源から写す）。問いと操作はすべてこれで渡す。
  private var drawn: Source.Rows
  /// 列の高さを決めた行の数（`reloadRows` で源から写す）。
  private(set) var rowCount = 0
  /// 区間の表（`reloadRows` で源から写す）。
  private var geometry = RowListSegments([])
  /// 留める行と、その上端を合わせる窓の中の高さ。
  private var anchor: (rows: RowListAnchor<Source.Selection>, windowY: CGFloat)?
  /// 錨のための一時の空き（文書の下）。
  private var bottomSpace: CGFloat = 0
  /// 押し続けの守り（錨を受け取った押下で張る）。
  private var pressGuard: RowListPressGuard?
  /// 行の高さの最小（枠の本数を決める）。
  private var minimumHeight: CGFloat
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
    drawn = source.rows
    minimumHeight = rowHeight
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.list)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    endPressGuard()
    guard window != nil else { return }
    applyFocusRequest()
    // 列が出た更新そのものには載せず、次の周回で済ませる。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      source.prepareRows(for: effectiveAppearance)
    }
  }

  // MARK: - 行

  /// 行の組を写し直し、行の数・高さ・中身を読み直す。見えている行の枠は捨てずに中身だけを差し替える。錨があれば、留める行を
  /// 押した行の高さへ送る。前の写しは裏で手放す（列が最後の持ち主になりうるので、数万行の組の解放を main に載せない）。
  func reloadRows() {
    let previous = drawn
    drawn = source.rows
    DispatchQueue.global(qos: .utility).async { withExtendedLifetime(previous) {} }
    rowCount = source.rowCount(in: drawn)
    geometry = RowListSegments(source.segments(in: drawn))
    minimumHeight = geometry.segments.map(\.height).min() ?? rowHeight
    holdAnchor()
    resizeDocument()
    layoutRows()
  }

  /// 選択 `selection` の描いている組での行。
  func row(of selection: Source.Selection) -> Int? {
    source.row(of: selection, in: drawn)
  }

  /// 文書の高さ（区間の表・最後の行の下の 1 行分の空き・一時の空き）。
  private func resizeDocument() {
    let height = geometry.height + rowHeight + bottomSpace
    guard frame.height != height else { return }
    setFrameSize(NSSize(width: frame.width, height: height))
  }

  func fitWidth(to width: CGFloat) {
    guard width != frame.width else { return }
    setFrameSize(NSSize(width: width, height: frame.height))
    for slot in slots { slot.setFrameSize(NSSize(width: width, height: slot.frame.height)) }
  }

  /// 見えている行に枠を割り当てて描かせる（行が見えなくなった枠は隠す）。
  func layoutRows() {
    let visible = visibleRect
    let capacity = Int((max(visible.height, minimumHeight) / minimumHeight).rounded(.up)) + 1
    while slots.count < capacity {
      let slot = source.makeRowView()
      slot.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight)
      addSubview(slot)
      slots.append(slot)
    }
    let count = min(source.rowCount(in: drawn), geometry.rowCount)
    let first = min(geometry.firstRow(from: max(0, visible.minY)), count)
    var shown = Set<Int>()
    var row = first
    while row < count {
      let rect = self.rect(ofRow: row)
      guard rect.minY < visible.maxY else { break }
      let index = row % slots.count
      shown.insert(index)
      let slot = slots[index]
      if slot.row != row { slot.row = row }
      if slot.frame != rect { slot.frame = rect }
      source.show(row, of: drawn, in: slot, emoji: emoji)
      slot.isSelected = row == selectedRow
      slot.isHidden = false
      row += 1
    }
    for (index, slot) in slots.enumerated() where !shown.contains(index) {
      slot.isHidden = true
      slot.row = nil
      slot.isSelected = false
      slot.pointer = nil
    }
  }

  /// 見えていなければ、見えるところまで最小限だけ送る（送るなら錨を外し、空きを取った後の行の枠で送る）。
  func scrollRowToVisible(_ row: Int) {
    guard row < geometry.rowCount else { return }
    let shown = rect(ofRow: row)
    let visible = visibleRect
    guard shown.minY < visible.minY || shown.maxY > visible.maxY else { return }
    releaseAnchor()
    let rect = rect(ofRow: row)
    scrollToVisible(NSRect(x: 0, y: rect.minY, width: 1, height: rect.height))
  }

  // MARK: - 錨

  /// 留める行の上端を、押した行の窓の中の高さへ送る。上へは原点が 0 に着くまで（列の上に空きを作らない）、下へ送りきれ
  /// なければ一時の空きを足して収める。留める行が組に無ければ、今の原点を保つ（手の下で列を跳ばさない）。合わせた後は、
  /// ポインタの下の行を今の位置で付け直す（動かさなくても、新しい行の部品が光る）。
  func holdAnchor() {
    guard let anchor, window != nil else { return }
    let visible = visibleRect
    var top = visible.minY
    if let target = anchoredRow(anchor.rows) {
      // 窓の高さが今の文書のどこに当たるか、から、見えている範囲の上端から錨までの距離を出す（送っても変わらない）。
      let offset = convert(NSPoint(x: 0, y: anchor.windowY), from: nil).y - visible.minY
      top = max(0, rect(ofRow: target).minY - offset)
    }
    bottomSpace = max(0, top + visible.height - (geometry.height + rowHeight))
    resizeDocument()
    if visible.minY != top { scroll(NSPoint(x: 0, y: top)) }
    layoutRows()
    updatePointer()
  }

  /// 錨を外す。一時の空きを取り、原点を範囲に収める。
  func releaseAnchor() {
    guard anchor != nil else { return }
    anchor = nil
    guard bottomSpace != 0 else { return }
    let top = visibleRect.minY
    bottomSpace = 0
    resizeDocument()
    scroll(NSPoint(x: 0, y: min(top, max(0, bounds.height - visibleRect.height))))
    layoutRows()
  }

  /// 錨の留める行（押した行が組に在ればその行、無ければ後継の行。どちらも無ければ nil）。
  private func anchoredRow(_ rows: RowListAnchor<Source.Selection>) -> Int? {
    let row =
      source.row(of: rows.pressed, in: drawn)
      ?? rows.successor.flatMap { source.row(of: $0, in: drawn) }
    return row.flatMap { $0 < rowCount ? $0 : nil }
  }

  // MARK: - 押し続けの守り

  /// 守りの問い——窓の押下 `event` が、留めている行の番号 `control` の部品に当たるか。列の外の view・見出し・別の行・行の
  /// 地に当たる押下と、錨が外れて留める行が無いときの押下は当たらない。
  private func admits(_ event: NSEvent, control: Int) -> Bool {
    guard let anchor, let target = anchoredRow(anchor.rows),
      window?.contentView?.hitTest(event.locationInWindow) === self
    else { return false }
    let point = convert(event.locationInWindow, from: nil)
    guard row(at: point) == target, let slot = slot(showing: target) else { return false }
    return slot.control(at: convert(point, to: slot))?.id == control
  }

  private func endPressGuard() {
    pressGuard?.end()
    pressGuard = nil
  }

  /// 行 `row`（区間の表の中）の枠。
  private func rect(ofRow row: Int) -> NSRect {
    let span = geometry.span(ofRow: row)
    return NSRect(x: 0, y: span.top, width: bounds.width, height: span.height)
  }

  private func row(at point: NSPoint) -> Int? {
    guard let row = geometry.row(atY: point.y), row < source.rowCount(in: drawn) else {
      return nil
    }
    return row
  }

  /// 見えている行 `row` の枠。
  private func slot(showing row: Int) -> Source.RowView? {
    slots.first { $0.row == row && !$0.isHidden }
  }

  // MARK: - ポインタ

  /// ポインタの下の行へ、行の中の位置を写す（ほかの行は外す）。部品の説明をツールチップにする。
  func updatePointer() {
    guard let window, let scroll = enclosingScrollView else { return pointerDidLeave() }
    let location = window.mouseLocationOutsideOfEventStream
    guard scroll.bounds.contains(scroll.convert(location, from: nil)) else {
      return pointerDidLeave()
    }
    let point = convert(location, from: nil)
    let target = row(at: point).flatMap(slot(showing:))
    for slot in slots where slot !== target { slot.pointer = nil }
    guard let target else {
      toolTip = nil
      return
    }
    let local = convert(point, to: target)
    target.pointer = local
    let help = target.help(at: local)
    if toolTip != help { toolTip = help }
  }

  func pointerDidLeave() {
    for slot in slots { slot.pointer = nil }
    toolTip = nil
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
    if let slot = slot(showing: row), let control = slot.control(at: convert(point, to: slot)) {
      let windowY = convert(NSPoint(x: 0, y: slot.frame.minY), to: nil).y
      endPressGuard()
      if let rows = source.press(row, control: control.id, in: drawn) {
        anchor = (rows, windowY)
        guard let window else { return }
        pressGuard = RowListPressGuard(
          window: window, frame: slot.convert(control.frame, to: nil)
        ) { [weak self] event in self?.admits(event, control: control.id) ?? false }
      } else {
        releaseAnchor()
      }
      return
    }
    if event.clickCount >= 2 {
      source.doubleClick(row, in: drawn)
    } else {
      source.click(row, in: drawn)
    }
  }

  // MARK: - キー

  /// 解釈中の押下がキーリピートか（`interpretKeyEvents` が同期に呼ぶ操作へ添える）。
  private var keyIsRepeat = false

  override func keyDown(with event: NSEvent) {
    releaseAnchor()
    keyIsRepeat = event.isARepeat
    defer { keyIsRepeat = false }
    interpretKeyEvents([event])
  }

  override func keyUp(with event: NSEvent) {
    source.keyDidRelease()
  }

  private func perform(_ action: RowListKey.Action) {
    source.perform(RowListKey(action: action, isRepeat: keyIsRepeat), in: drawn)
  }

  override func moveUp(_ sender: Any?) { perform(.up) }
  override func moveDown(_ sender: Any?) { perform(.down) }
  override func moveUpAndModifySelection(_ sender: Any?) { perform(.up) }
  override func moveDownAndModifySelection(_ sender: Any?) { perform(.down) }
  override func moveLeft(_ sender: Any?) { perform(.left) }
  override func moveRight(_ sender: Any?) { perform(.right) }
  override func insertNewline(_ sender: Any?) { perform(.enter) }
  override func cancelOperation(_ sender: Any?) { perform(.escape) }

  override func scrollToBeginningOfDocument(_ sender: Any?) {
    scroll(NSPoint(x: 0, y: 0))
  }

  override func scrollToEndOfDocument(_ sender: Any?) {
    scroll(NSPoint(x: 0, y: max(0, bounds.height - visibleRect.height)))
  }

  override func scrollPageUp(_ sender: Any?) { page(by: -1) }
  override func scrollPageDown(_ sender: Any?) { page(by: 1) }
  override func pageUp(_ sender: Any?) { page(by: -1) }
  override func pageDown(_ sender: Any?) { page(by: 1) }

  /// 1 画面ぶん送る（行 1 つ分重ねて、読んでいた行を見失わない）。`direction` は上が -1、下が 1。
  private func page(by direction: CGFloat) {
    let step = max(rowHeight, visibleRect.height - rowHeight) * direction
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
    source.select(row, in: drawn)
  }

  override func accessibilityRowCount() -> Int { source.rowCount(in: drawn) }
}

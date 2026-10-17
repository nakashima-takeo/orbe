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
final class RowListView<Source: RowListSource>: NSView {
  let source: Source
  let rowHeight: CGFloat
  var emoji: NSFont?
  /// 列の高さを決めた行の数（`reloadRows` で源から写す）。行を問う上限は源の今の行の数。
  private(set) var rowCount = 0
  /// 区間の表と、各区間の上端（`reloadRows` で源から写す）。
  private var segments: [RowListSegment] = []
  private var segmentTops: [CGFloat] = []
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
    minimumHeight = rowHeight
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

  /// 行の数・高さ・中身を読み直す。見えている行の枠は捨てずに中身だけを差し替える。
  func reloadRows() {
    rowCount = source.rowCount
    segments = source.rowSegments
    var top: CGFloat = 0
    segmentTops = segments.map { segment in
      top += segment.leading
      defer { top += CGFloat(segment.count) * segment.height }
      return top
    }
    minimumHeight = segments.map(\.height).min() ?? rowHeight
    setFrameSize(NSSize(width: frame.width, height: top + rowHeight))
    layoutRows()
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
    let count = min(source.rowCount, segments.last.map { $0.start + $0.count } ?? 0)
    let first = min(firstRow(from: max(0, visible.minY)), count)
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
      source.show(row, in: slot, emoji: emoji)
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

  /// 見えていなければ、見えるところまで最小限だけ送る。
  func scrollRowToVisible(_ row: Int) {
    guard row < segments.last.map({ $0.start + $0.count }) ?? 0 else { return }
    let rect = rect(ofRow: row)
    scrollToVisible(NSRect(x: 0, y: rect.minY, width: 1, height: rect.height))
  }

  /// 行 `row`（区間の表の中）の枠。
  private func rect(ofRow row: Int) -> NSRect {
    var low = 0
    var high = segments.count
    while high - low > 1 {
      let mid = (low + high) / 2
      if segments[mid].start <= row { low = mid } else { high = mid }
    }
    let segment = segments[low]
    return NSRect(
      x: 0, y: segmentTops[low] + CGFloat(row - segment.start) * segment.height,
      width: bounds.width, height: segment.height)
  }

  /// 高さ `y` の行（区間の表の外・区間の前の余白なら nil）。
  private func row(atY y: CGFloat) -> Int? {
    guard let low = segment(atY: y), y >= segmentTops[low] else { return nil }
    let segment = segments[low]
    let offset = Int((y - segmentTops[low]) / segment.height)
    return offset < segment.count ? segment.start + offset : nil
  }

  /// 下端が `y` より下にある最初の行（余白の上なら、その下の行）。
  private func firstRow(from y: CGFloat) -> Int {
    guard let low = segment(atY: y) else { return 0 }
    let segment = segments[low]
    guard y >= segmentTops[low] else { return segment.start }
    let offset = Int((y - segmentTops[low]) / segment.height)
    if offset < segment.count { return segment.start + offset }
    return low + 1 < segments.count ? segments[low + 1].start : segment.start + segment.count
  }

  /// 高さ `y` を含む区間（前の余白を含めて、上端が `y` 以下の最後の区間）。最初の区間の余白の上も最初の区間。
  private func segment(atY y: CGFloat) -> Int? {
    guard y >= 0, !segments.isEmpty else { return nil }
    var low = 0
    var high = segmentTops.count
    while high - low > 1 {
      let mid = (low + high) / 2
      if segmentTops[mid] - segments[mid].leading <= y { low = mid } else { high = mid }
    }
    return low
  }

  private func row(at point: NSPoint) -> Int? {
    guard let row = row(atY: point.y), row < source.rowCount else { return nil }
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
      source.press(row, control: control)
      return
    }
    if event.clickCount >= 2 {
      source.doubleClick(row)
    } else {
      source.click(row)
    }
  }

  // MARK: - キー

  /// 解釈中の押下がキーリピートか（`interpretKeyEvents` が同期に呼ぶ操作へ添える）。
  private var keyIsRepeat = false

  override func keyDown(with event: NSEvent) {
    keyIsRepeat = event.isARepeat
    defer { keyIsRepeat = false }
    interpretKeyEvents([event])
  }

  override func keyUp(with event: NSEvent) {
    source.keyDidRelease()
  }

  private func perform(_ action: RowListKey.Action) {
    source.perform(RowListKey(action: action, isRepeat: keyIsRepeat))
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
    source.select(row)
  }

  override func accessibilityRowCount() -> Int { source.rowCount }
}

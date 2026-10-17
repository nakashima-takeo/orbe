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
/// 部品の押下に源が錨を返せば、留める行の上端を押した行の窓の中の高さに合わせ続ける（→ `RowListAnchor`）。送れる範囲の外に
/// 出るなら、文書の上か下に一時の空きを足して収める。外せば空きを取り、原点を範囲に収める。
final class RowListView<Source: RowListSource>: NSView {
  let source: Source
  let rowHeight: CGFloat
  var emoji: NSFont?
  /// 描いている行の組（`reloadRows` で源から写す）。問いと操作はすべてこれで渡す。
  private var drawn: Source.Rows
  /// 列の高さを決めた行の数（`reloadRows` で源から写す）。
  private(set) var rowCount = 0
  /// 区間の表と、各区間の上端（`reloadRows` で源から写す。一時の空きを含まない）。
  private var segments: [RowListSegment] = []
  private var segmentTops: [CGFloat] = []
  /// 区間の表の高さ（最後の行の下の 1 行分の空きと、一時の空きを含まない）。
  private var contentHeight: CGFloat = 0
  /// 留める行と、その上端を合わせる窓の中の高さ。
  private var anchor: (rows: RowListAnchor<Source.Selection>, windowY: CGFloat)?
  /// 錨のための一時の空き（文書の上と下）。
  private var topSpace: CGFloat = 0
  private var bottomSpace: CGFloat = 0
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
  /// 押した行の高さへ送る。
  func reloadRows() {
    drawn = source.rows
    rowCount = source.rowCount(in: drawn)
    segments = source.segments(in: drawn)
    var top: CGFloat = 0
    segmentTops = segments.map { segment in
      top += segment.leading
      defer { top += CGFloat(segment.count) * segment.height }
      return top
    }
    contentHeight = top
    minimumHeight = segments.map(\.height).min() ?? rowHeight
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
    let height = topSpace + contentHeight + rowHeight + bottomSpace
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
    let count = min(source.rowCount(in: drawn), segments.last.map { $0.start + $0.count } ?? 0)
    let first = min(firstRow(from: max(0, visible.minY - topSpace)), count)
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
    guard row < segments.last.map({ $0.start + $0.count }) ?? 0 else { return }
    let shown = rect(ofRow: row)
    let visible = visibleRect
    guard shown.minY < visible.minY || shown.maxY > visible.maxY else { return }
    releaseAnchor()
    let rect = rect(ofRow: row)
    scrollToVisible(NSRect(x: 0, y: rect.minY, width: 1, height: rect.height))
  }

  // MARK: - 錨

  /// 留める行の上端を、押した行の窓の中の高さへ送る。送れる範囲の外なら一時の空きを足して収める。留める行が組から消えたら
  /// 外す。合わせた後は、ポインタの下の行を今の位置で付け直す（動かさなくても、新しい行の部品が光る）。
  func holdAnchor() {
    guard let anchor, window != nil else { return }
    let target =
      source.row(of: anchor.rows.pressed, in: drawn)
      ?? source.row(of: anchor.rows.successor, in: drawn)
    guard let target, target < rowCount, !segments.isEmpty else { return releaseAnchor() }
    let visible = visibleRect
    // 窓の高さが今の文書のどこに当たるか、から、見えている範囲の上端から錨までの距離を出す（送っても変わらない）。
    let offset = convert(NSPoint(x: 0, y: anchor.windowY), from: nil).y - visible.minY
    let origin = rect(ofRow: target).minY - topSpace - offset
    topSpace = max(0, -origin)
    let top = max(0, origin)
    bottomSpace = max(0, top + visible.height - (contentHeight + rowHeight + topSpace))
    resizeDocument()
    if visible.minY != top { scroll(NSPoint(x: 0, y: top)) }
    layoutRows()
    updatePointer()
  }

  /// 錨を外す。一時の空きを取り、原点を範囲に収める。
  func releaseAnchor() {
    guard anchor != nil else { return }
    anchor = nil
    guard topSpace != 0 || bottomSpace != 0 else { return }
    let top = visibleRect.minY - topSpace
    topSpace = 0
    bottomSpace = 0
    resizeDocument()
    scroll(NSPoint(x: 0, y: min(max(0, top), max(0, bounds.height - visibleRect.height))))
    layoutRows()
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
      x: 0, y: topSpace + segmentTops[low] + CGFloat(row - segment.start) * segment.height,
      width: bounds.width, height: segment.height)
  }

  /// 区間の表の高さ `y`（一時の空きを除く）の行（区間の表の外・区間の前の余白なら nil）。
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
    guard let row = row(atY: point.y - topSpace), row < source.rowCount(in: drawn) else {
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
      if let rows = source.press(row, control: control, in: drawn) {
        anchor = (rows, windowY)
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

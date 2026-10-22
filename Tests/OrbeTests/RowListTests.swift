import AppKit
import XCTest

@testable import Orbe

/// 行の列の部品（`RowList`）そのもの——検索に依らない最小の源で、枠の使い回しと新しく見えた行だけの描き直し、キーの
/// 渡し方（Home / End・Page は列が送る）、押した行と行の中の部品、選べる行の無い列は焦点を取らないこと、選択が変わったときだけ
/// 見せること、焦点の要求、VoiceOver のリストを固める。
///
/// 壊れると何が起きるか。送るたびに見えている行を全部描き直して重い、行の数が変わるたびに枠を作り直す。↑↓ や Enter が
/// 源へ届かない、Home / End で送れない。押した行と違う行が開く・行の中のボタンを押すと別の行のボタンになるか行のクリックに
/// なる。選べる行の無い列（ソース管理のグラフ）を押すと、別の列の焦点が抜けて ↑↓ がどこにも効かなくなる。選んだ行が見えているのに送られる、見えていないのに寄らない。結果が
/// 届くたびに選択の行へ引き戻される。末尾まで送っても最後の行が下端に付く。つまみを掴めない・引いてもポインタに付いてこない、
/// 消えているつまみや帯が行のクリックを奪う。
@MainActor
final class RowListTests: OrbeTestCase {
  let rowHeight: CGFloat = 20

  struct Hosted {
    let source: Source
    let rows: RowList<Source>
    let window: NSWindow
    @MainActor var list: RowListView<Source> { rows.list }
  }

  /// 幅 200・高さ 100（5 行ぶん）の列を窓に載せ、行を読ませる。
  func host(rowCount: Int = 200) -> Hosted {
    let source = Source()
    source.rowCount = rowCount
    let rows = RowList(source: source, rowHeight: rowHeight)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = rows
    rows.update(rowsVersion: 0, selection: nil, emoji: nil, wantsFocus: false)
    rows.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    return Hosted(source: source, rows: rows, window: window)
  }

  func slots(_ list: RowListView<Source>) -> [Row] {
    list.subviews.compactMap { $0 as? Row }
  }

  /// 行 `row` を描いている枠（見えていなければ nil）。
  func slot(_ list: RowListView<Source>, _ row: Int) -> Row? {
    slots(list).first { $0.row == row && !$0.isHidden }
  }

  func key(_ special: NSEvent.SpecialKey) -> NSEvent {
    .key(String(UnicodeScalar(special.rawValue)!), [])
  }

  private func draws(_ hosted: Hosted) -> Int {
    hosted.window.displayIfNeeded()
    CATransaction.flush()
    return slots(hosted.list).reduce(0) { $0 + $1.draws }
  }

  func scroll(_ hosted: Hosted, by step: CGFloat) {
    let clip = hosted.rows.contentView
    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + step))
    hosted.rows.reflectScrolledClipView(clip)
  }

  /// 列の座標 `point` を押す。
  func press(_ hosted: Hosted, at point: NSPoint, clickCount: Int = 1) {
    hosted.list.mouseDown(
      with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: hosted.list.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0,
        clickCount: clickCount, pressure: 1)!)
  }

  // MARK: - 枠

  /// 枠は見えている行の数＋1 本だけで、行 r を枠 r mod 本数 に割り当てる。送って描き直すのは新しく見えた行だけ（端で
  /// 見え方の変わる行を含めて 2 行まで）。行の数が変わっても枠は作り直さず、列の高さだけが変わる。
  func testSlotsAreReusedAndScrollingRedrawsOnlyTheNewlyVisibleRows() {
    let hosted = host()
    let list = hosted.list
    XCTAssertEqual(list.frame.height, rowHeight * 201, "行の数ぶん＋最後の行の下に 1 行分の空き")
    XCTAssertEqual(slots(list).count, 6, "見えている 5 行＋1 本")
    XCTAssertEqual(slot(list, 4)?.label, "row 4")
    XCTAssertNil(slot(list, 5), "見えていない行は描かない")
    XCTAssertEqual(draws(hosted), 5, "見えている行を 1 度ずつ描く")

    for step in [rowHeight, 7, rowHeight, 7] {
      let before = draws(hosted)
      scroll(hosted, by: step)
      XCTAssertLessThanOrEqual(draws(hosted) - before, 2, "\(step)pt 送る")
    }
    let top = Int(list.visibleRect.minY / rowHeight)
    XCTAssertEqual(slot(list, top)?.label, "row \(top)")
    XCTAssertTrue(slot(list, top) === slots(list)[top % 6], "行 r は枠 r mod 本数")

    let kept = slots(list)
    hosted.source.rowCount = 3
    hosted.rows.update(
      rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.rowCount, 3)
    XCTAssertEqual(list.frame.height, rowHeight * 4, "行の数の変化は列の高さだけで受ける")
    XCTAssertEqual(
      slots(list).map(ObjectIdentifier.init), kept.map(ObjectIdentifier.init), "枠は作り直さない")
    XCTAssertEqual(slot(list, 2)?.label, "row 2")
    XCTAssertEqual(slots(list).filter { !$0.isHidden }.count, 3, "無い行の枠は隠れる")

    hosted.source.rowCount = 200
    hosted.rows.update(
      rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.rowCount, 3, "版が同じなら読み直さない")
  }

  /// 源の行が減ってから列が読み直すまでの間に送る・押しても、源の今の行の数の外の行は問わない（イベントは SwiftUI の
  /// 更新より先に届きうる）。
  func testRowsOutsideTheSourcesCurrentCountAreNeverAsked() {
    let hosted = host()
    let list = hosted.list
    hosted.source.rowCount = 2
    scroll(hosted, by: rowHeight)
    list.pageDown(nil)
    press(hosted, at: NSPoint(x: 10, y: list.visibleRect.midY))
    XCTAssertEqual(hosted.source.outOfRange, 0)
    XCTAssertEqual(list.accessibilityRowCount(), 2)
  }

  // MARK: - キー

  /// ↑↓←→・Enter・Esc は源の操作へ、キーリピートかを添えて渡り、離したことも源へ渡る。Home / End・PageUp / PageDown は源へ渡さず、列が送るだけ。
  func testKeysReachTheSourceAndScrollKeysOnlyScroll() {
    let hosted = host()
    let list = hosted.list
    for special in [NSEvent.SpecialKey.upArrow, .downArrow, .leftArrow, .rightArrow] {
      list.keyDown(with: key(special))
    }
    list.keyDown(with: .key("\r", []))
    list.keyDown(with: .key("\u{1b}", []))
    list.keyDown(
      with: .key(String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!), [], isRepeat: true))
    XCTAssertEqual(
      hosted.source.keys.map(\.action), [.up, .down, .left, .right, .enter, .escape, .down])
    XCTAssertEqual(
      hosted.source.keys.map(\.isRepeat), [false, false, false, false, false, false, true],
      "キーリピートを運ぶ")
    list.keyUp(with: .keyRelease(String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)))
    XCTAssertEqual(hosted.source.releases, 1, "離したことを源へ渡す")

    let height = list.visibleRect.height
    list.scrollToEndOfDocument(nil)
    XCTAssertEqual(list.visibleRect.maxY, list.frame.height, accuracy: 0.5, "End は末尾へ送る")
    XCTAssertEqual(
      list.visibleRect.maxY - CGFloat(list.rowCount) * rowHeight, rowHeight, accuracy: 0.5,
      "最後の行の下に 1 行分の空きが残る")
    list.scrollToBeginningOfDocument(nil)
    XCTAssertEqual(list.visibleRect.minY, 0, "Home は先頭へ送る")
    list.pageDown(nil)
    XCTAssertEqual(list.visibleRect.minY, height - rowHeight, accuracy: 0.5, "1 行重ねて 1 画面送る")
    list.pageUp(nil)
    XCTAssertEqual(list.visibleRect.minY, 0)
    XCTAssertEqual(hosted.source.keys.count, 7, "送るキーは源へ渡さない")
  }

  // MARK: - マウス

  /// 押すと焦点を取り、押した位置の行の番号を源へ渡す（ダブルクリックは別の口）。行の中の部品の上なら、行のクリックでは
  /// なく部品の押下として渡す。行の無いところ（最後の行の下の空き）は渡さない。
  func testClicksPassTheRowAndPressesPassTheControl() {
    let hosted = host(rowCount: 4)
    let list = hosted.list
    func press(x: CGFloat, y: CGFloat, count: Int) {
      self.press(hosted, at: NSPoint(x: x, y: y), clickCount: count)
    }
    press(x: 13, y: 1.5 * rowHeight, count: 1)
    XCTAssertTrue(hosted.window.firstResponder === list, "押すと焦点を取る")
    press(x: 13, y: 2.5 * rowHeight, count: 1)
    press(x: 150, y: 0.5 * rowHeight, count: 2)
    press(x: 190, y: 3.5 * rowHeight, count: 1)
    press(x: 20, y: 4.5 * rowHeight, count: 1)  // 最後の行の下の空き
    XCTAssertEqual(hosted.source.clicks, ["click 1", "click 2", "double 0", "press 3 0"])
  }

  /// 選べる行の無い源の列は焦点を受けず（AppKit は押された view が受けるなら押下の前に焦点を移す）、列の押下でも焦点を
  /// 取らないので、別の view の焦点はそのまま。押した行は源へ渡る。
  func testAListWithoutSelectableRowsPassesClicksButNeverTakesTheFocus() {
    let rows = RowList(source: RowListUnselectableSource(), rowHeight: rowHeight)
    let other = NSTextView(frame: NSRect(x: 0, y: 100, width: 200, height: 20))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
    rows.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
    container.addSubview(rows)
    container.addSubview(other)
    let window = NSWindow(
      contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = container
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    rows.update(rowsVersion: 0, selection: nil, emoji: nil, wantsFocus: false)
    rows.layoutSubtreeIfNeeded()
    window.makeFirstResponder(other)
    let list = rows.list
    XCTAssertFalse(list.acceptsFirstResponder)

    list.mouseDown(
      with: .mouse(
        .leftMouseDown, at: list.convert(NSPoint(x: 13, y: 2.5 * rowHeight), to: nil), in: window))
    XCTAssertTrue(window.firstResponder === other, "焦点はそのまま")
    XCTAssertEqual(list.source.clicks, [2], "押した行は源へ渡る")
  }

  // MARK: - つまみ

  /// 当たりは見えているつまみだけ——列を出しただけの（消えている）つまみも、帯のつまみの外も行へ通る。掴んで引くと、
  /// つまみがポインタに付いて動く。
  func testOnlyTheShownThumbIsGrabbedAndItFollowsTheDrag() {
    let hosted = host()
    let rows = hosted.rows
    let thumb = rows.scrollbar
    /// 列の座標の点を、hitTest が受ける親の座標へ。
    func inParent(_ point: NSPoint) -> NSPoint { rows.superview!.convert(point, from: rows) }
    var onThumb: NSPoint { inParent(NSPoint(x: thumb.frame.midX, y: thumb.frame.midY)) }
    XCTAssertFalse(rows.hitTest(onThumb) === thumb, "消えているつまみは当たらない")

    scroll(hosted, by: 1)
    XCTAssertTrue(rows.hitTest(onThumb) === thumb, "位置が変わると見えて当たる")
    let band = inParent(NSPoint(x: thumb.frame.midX, y: thumb.frame.maxY + rowHeight))
    XCTAssertTrue(
      rows.hitTest(band)?.isDescendant(of: hosted.list) == true, "帯のつまみの外は行へ通る")

    func mouse(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: onThumb.x, y: y), modifierFlags: [], timestamp: 0,
        windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1)!
    }
    let grab = onThumb.y
    let top = thumb.frame.minY
    thumb.mouseDown(with: mouse(.leftMouseDown, y: grab))
    thumb.mouseDragged(with: mouse(.leftMouseDragged, y: grab - 8))
    XCTAssertEqual(thumb.frame.minY - top, 8, accuracy: 0.5, "8pt 引けばつまみも 8pt 下りる")
    thumb.mouseUp(with: mouse(.leftMouseUp, y: grab - 8))
  }

  /// ポインタの真下で窓に載り直した列（入った通知は来ない）でも、上でポインタを動かせばつまみが見える。外で動いても
  /// 見せない（焦点のある列へは外の動きも届く）。
  func testMovingThePointerOverAReplacedListShowsTheThumb() {
    let hosted = host()
    let rows = hosted.rows
    let thumb = rows.scrollbar
    hosted.window.contentView = nil
    hosted.window.contentView = rows
    rows.layoutSubtreeIfNeeded()
    let onThumb = rows.superview!.convert(
      NSPoint(x: thumb.frame.midX, y: thumb.frame.midY), from: rows)
    func moved(to point: NSPoint) {
      rows.mouseMoved(
        with: NSEvent.mouseEvent(
          with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1)!)
    }
    moved(to: NSPoint(x: 100, y: 300))
    XCTAssertFalse(rows.hitTest(onThumb) === thumb, "外で動いても見せない")
    moved(to: NSPoint(x: 100, y: 50))
    XCTAssertTrue(rows.hitTest(onThumb) === thumb, "上で動けば見える")
  }

  // MARK: - 送り

  /// 大きさが決まる前（SwiftUI の最初の更新）に変わった選択は、大きさが付いてから見せる——大きさの無いまま送った位置が
  /// 残ると、選択の行が上端で半分隠れる。
  func testASelectionRevealedBeforeTheListHasASizeIsShownOnceItDoes() {
    for (selection, check) in [(50, "見えるところまで"), (0, "先頭の行は欠けない")] {
      let source = Source()
      let rows = RowList(source: source, rowHeight: rowHeight)
      rows.update(
        rowsVersion: 0, selection: selection, emoji: nil, wantsFocus: false)
      rows.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
      rows.tile()
      if selection == 0 {
        XCTAssertEqual(rows.list.visibleRect.minY, 0, check)
      } else {
        XCTAssertEqual(
          rows.list.visibleRect.maxY, CGFloat(selection + 1) * rowHeight, accuracy: 0.5, check)
      }
    }
  }

  /// 選択の行を写し、選択が変わったときだけ、その行が見えるところまで最小限だけ送る（見えていれば動かさない）。同じ選択の
  /// まま行がずれても・版が変わっても送らない。
  func testTheSelectionIsMirroredAndRevealedOnlyWhenItChanges() {
    let hosted = host()
    let list = hosted.list
    hosted.rows.update(
      rowsVersion: 0, selection: 50, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.selectedRow, 50)
    XCTAssertEqual(list.visibleRect.maxY, 51 * rowHeight, accuracy: 0.5, "変わった選択を最小限に")
    XCTAssertEqual(slots(list).filter(\.isSelected).map(\.row), [50], "選択の枠だけが選択")

    list.scrollToBeginningOfDocument(nil)
    hosted.rows.update(
      rowsVersion: 1, selection: 50, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.visibleRect.minY, 0, "同じ選択では送らない")

    hosted.rows.update(
      rowsVersion: 1, selection: 2, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.visibleRect.minY, 0, "見えている選択では動かない")
    hosted.rows.update(
      rowsVersion: 1, selection: 60, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.visibleRect.maxY, 61 * rowHeight, accuracy: 0.5, "変わった選択を最小限に")
    hosted.rows.update(
      rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertNil(list.selectedRow)
    XCTAssertTrue(slots(list).allSatisfy { !$0.isSelected })
  }

  // MARK: - 焦点

  /// 焦点の要求は列が窓の中で当てて源へ返し、焦点の出入りを源へ知らせる。
  func testTheFocusRequestIsAppliedAndTheFocusIsReported() {
    let hosted = host()
    hosted.source.wantsFocus = true
    hosted.rows.update(
      rowsVersion: 0, selection: nil, emoji: nil, wantsFocus: true)
    pumpMain(until: { hosted.window.firstResponder === hosted.list }, "要求で列に焦点")
    XCTAssertEqual(hosted.source.focusRequestsApplied, 1)
    hosted.window.makeFirstResponder(nil)
    XCTAssertEqual(hosted.source.focus, [true, false])
  }

  // MARK: - アクセシビリティ

  /// VoiceOver には行の総数を持つリストとして、見えている行を上から順に（中身・何行目か）見せ、選択を伝える。リストの行を
  /// 選べば源の選択になる。
  func testTheListIsAnAccessibilityListOfTheVisibleRows() throws {
    let hosted = host()
    let list = hosted.list
    hosted.rows.update(
      rowsVersion: 0, selection: 2, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.accessibilityRole(), .list)
    XCTAssertEqual(list.accessibilityRowCount(), 200)
    list.pageDown(nil)
    var rows = try XCTUnwrap(list.accessibilityRows() as? [Row])
    let top = Int(list.visibleRect.minY / rowHeight)
    XCTAssertEqual(
      rows.map { $0.accessibilityIndex() }, Array(top..<(top + rows.count)), "上から順に何行目か")
    XCTAssertEqual(rows.first?.accessibilityRole(), .row)
    XCTAssertEqual(rows.first?.accessibilityLabel(), "row \(top)")
    XCTAssertEqual(list.accessibilityVisibleRows()?.count, rows.count)
    XCTAssertEqual(list.accessibilitySelectedRows()?.count, 0, "選択は見えていない")

    list.scrollToBeginningOfDocument(nil)
    rows = try XCTUnwrap(list.accessibilityRows() as? [Row])
    XCTAssertTrue((list.accessibilitySelectedRows() as? [Row])?.first === rows[2])
    XCTAssertTrue(rows[2].isAccessibilitySelected())
    list.setAccessibilitySelectedRows([rows[4]])
    XCTAssertEqual(hosted.source.selected, [4], "リストの行を選ぶと源の選択")
  }
}

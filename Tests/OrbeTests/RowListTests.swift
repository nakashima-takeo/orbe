import AppKit
import XCTest

@testable import Orbe

/// 行の列の部品（`RowList`）そのもの——検索に依らない最小の源で、枠の使い回しと新しく見えた行だけの描き直し、キーの
/// 渡し方（Home / End・Page を源が扱う／扱わない、Space、文字の打鍵の引き取り）、押した行と行の中の横の位置、2 通りの
/// 送り、選択が変わったときだけ見せること、焦点の要求、VoiceOver のリストを固める。
///
/// 壊れると何が起きるか。送るたびに見えている行を全部描き直して重い、行の数が変わるたびに枠を作り直す。源が扱う
/// Home / End でも列が勝手に送る、打鍵が入力欄へ回らず IME が最初の字から効かない。押したシェブロンが開閉しない。
/// カーソルを追う行が見えているのに送られる、見えていないのに寄らない。結果が届くたびに選択の行へ引き戻される。
@MainActor
final class RowListTests: OrbeTestCase {
  private let rowHeight: CGFloat = 20

  /// 源の偽物。行 r の中身は "row r"、選択の同一性は行の番号そのもの。受けた操作を記録する。
  final class Source: RowListSource {
    var rowCount = 200
    var wantsFocus = false
    /// 扱うキー（ほかは扱わない＝false を返す）。
    var handles: Set<RowListKey> = [.up, .down, .left, .right, .enter, .escape, .space]
    /// 引き取る打鍵（文字）。
    var takes: Set<String> = []
    private(set) var keys: [RowListKey] = []
    private(set) var taken: [String] = []
    private(set) var clicks: [String] = []
    private(set) var selected: [Int] = []
    private(set) var focus: [Bool] = []
    private(set) var focusRequestsApplied = 0
    /// 今の行の数の外の行を問われた回数。
    private(set) var outOfRange = 0

    func makeRowView() -> Row { Row(frame: .zero) }
    func show(_ row: Int, in view: Row, emoji: NSFont?) {
      if row >= rowCount { outOfRange += 1 }
      view.show("row \(row)")
    }
    func row(of selection: Int) -> Int? { selection < rowCount ? selection : nil }
    func prepareRows(for appearance: NSAppearance) {}
    func focusRequestDidApply() {
      wantsFocus = false
      focusRequestsApplied += 1
    }
    func focusDidChange(_ focused: Bool) { focus.append(focused) }
    func takeTyping(_ event: NSEvent) -> Bool {
      guard let characters = event.characters, takes.contains(characters) else { return false }
      taken.append(characters)
      return true
    }
    func perform(_ key: RowListKey) -> Bool {
      keys.append(key)
      return handles.contains(key)
    }
    func click(_ row: Int, x: CGFloat) {
      if row >= rowCount { outOfRange += 1 }
      clicks.append("click \(row) x\(Int(x))")
    }
    func doubleClick(_ row: Int, x: CGFloat) { clicks.append("double \(row) x\(Int(x))") }
    func select(_ row: Int) { selected.append(row) }
  }

  /// 行の偽物。中身が変わったときだけ描き直す（描いた回数を数える）。
  final class Row: ListRowView {
    private(set) var label: String?
    private(set) var draws = 0

    func show(_ label: String) {
      guard label != self.label else { return }
      self.label = label
      setAccessibilityLabel(label)
      needsDisplay = true
    }

    override func drawContent(_ colors: RowColors, in context: CGContext) { draws += 1 }
  }

  private struct Hosted {
    let source: Source
    let rows: RowList<Source>
    let window: NSWindow
    @MainActor var list: RowListView<Source> { rows.list }
  }

  /// 幅 200・高さ 100（5 行ぶん）の列を窓に載せ、行を読ませる。
  private func host(rowCount: Int = 200) -> Hosted {
    let source = Source()
    source.rowCount = rowCount
    let rows = RowList(source: source, rowHeight: rowHeight)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = rows
    rows.update(rowsVersion: 0, selection: nil, reveal: .nearest, emoji: nil, wantsFocus: false)
    rows.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    return Hosted(source: source, rows: rows, window: window)
  }

  private func slots(_ list: RowListView<Source>) -> [Row] {
    list.subviews.compactMap { $0 as? Row }
  }

  /// 行 `row` を描いている枠（見えていなければ nil）。
  private func slot(_ list: RowListView<Source>, _ row: Int) -> Row? {
    slots(list).first { $0.row == row && !$0.isHidden }
  }

  private func key(_ special: NSEvent.SpecialKey) -> NSEvent {
    .key(String(UnicodeScalar(special.rawValue)!), [])
  }

  private func draws(_ hosted: Hosted) -> Int {
    hosted.window.displayIfNeeded()
    CATransaction.flush()
    return slots(hosted.list).reduce(0) { $0 + $1.draws }
  }

  private func scroll(_ hosted: Hosted, by step: CGFloat) {
    let clip = hosted.rows.contentView
    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + step))
    hosted.rows.reflectScrolledClipView(clip)
  }

  // MARK: - 枠

  /// 枠は見えている行の数＋1 本だけで、行 r を枠 r mod 本数 に割り当てる。送って描き直すのは新しく見えた行だけ（端で
  /// 見え方の変わる行を含めて 2 行まで）。行の数が変わっても枠は作り直さず、列の高さだけが変わる。
  func testSlotsAreReusedAndScrollingRedrawsOnlyTheNewlyVisibleRows() {
    let hosted = host()
    let list = hosted.list
    XCTAssertEqual(list.frame.height, rowHeight * 200, "行の高さは 1 つ")
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
      rowsVersion: 1, selection: nil, reveal: .nearest, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.rowCount, 3)
    XCTAssertEqual(list.frame.height, rowHeight * 3, "行の数の変化は列の高さだけで受ける")
    XCTAssertEqual(
      slots(list).map(ObjectIdentifier.init), kept.map(ObjectIdentifier.init), "枠は作り直さない")
    XCTAssertEqual(slot(list, 2)?.label, "row 2")
    XCTAssertEqual(slots(list).filter { !$0.isHidden }.count, 3, "無い行の枠は隠れる")

    hosted.source.rowCount = 200
    hosted.rows.update(
      rowsVersion: 1, selection: nil, reveal: .nearest, emoji: nil, wantsFocus: false)
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
    list.mouseDown(
      with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: list.convert(NSPoint(x: 10, y: list.visibleRect.midY), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)!)
    XCTAssertEqual(hosted.source.outOfRange, 0)
    XCTAssertEqual(list.accessibilityRowCount(), 2)
  }

  // MARK: - キー

  /// キーは源の操作へ渡る。Home / End・PageUp / PageDown は源が扱えば列は送らず、扱わなければ送るだけ。Space は
  /// 文字として届いて源の Space へ。源が引き取る打鍵は、列はキーとして解かない。
  func testKeysReachTheSourceAndScrollKeysScrollOnlyWhenTheSourceDoesNotHandleThem() {
    let hosted = host()
    let list = hosted.list
    for special in [NSEvent.SpecialKey.upArrow, .downArrow, .leftArrow, .rightArrow] {
      list.keyDown(with: key(special))
    }
    list.keyDown(with: .key("\r", []))
    list.keyDown(with: .key("\u{1b}", []))
    list.keyDown(with: .key(" ", []))
    XCTAssertEqual(hosted.source.keys, [.up, .down, .left, .right, .enter, .escape, .space])

    let height = list.visibleRect.height
    list.scrollToEndOfDocument(nil)
    XCTAssertEqual(list.visibleRect.maxY, list.frame.height, accuracy: 0.5, "扱わない End は末尾へ送る")
    list.scrollToBeginningOfDocument(nil)
    XCTAssertEqual(list.visibleRect.minY, 0, "扱わない Home は先頭へ送る")
    list.pageDown(nil)
    XCTAssertEqual(list.visibleRect.minY, height - rowHeight, accuracy: 0.5, "1 行重ねて 1 画面送る")
    list.pageUp(nil)
    XCTAssertEqual(list.visibleRect.minY, 0)

    hosted.source.handles.formUnion([.home, .end, .pageUp, .pageDown])
    list.scrollToEndOfDocument(nil)
    list.pageDown(nil)
    XCTAssertEqual(list.visibleRect.minY, 0, "源が扱えば列は送らない")
    XCTAssertEqual(hosted.source.keys.suffix(2), [.end, .pageDown])

    hosted.source.takes = [" "]
    let performed = hosted.source.keys.count
    list.keyDown(with: .key(" ", []))
    XCTAssertEqual(hosted.source.taken, [" "], "源が打鍵を引き取る")
    XCTAssertEqual(hosted.source.keys.count, performed, "引き取った打鍵は解かない")
  }

  // MARK: - マウス

  /// 押すと焦点を取り、行の番号と行の中の横の位置を源へ渡す（ダブルクリックは別の口）。行の無いところは渡さない。
  func testClicksPassTheRowAndTheXInTheRow() {
    let hosted = host(rowCount: 3)
    let list = hosted.list
    func press(x: CGFloat, y: CGFloat, count: Int) {
      list.mouseDown(
        with: NSEvent.mouseEvent(
          with: .leftMouseDown, location: list.convert(NSPoint(x: x, y: y), to: nil),
          modifierFlags: [], timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil,
          eventNumber: 0, clickCount: count, pressure: 1)!)
    }
    press(x: 13, y: 2.5 * rowHeight, count: 1)
    XCTAssertTrue(hosted.window.firstResponder === list, "押すと焦点を取る")
    press(x: 150, y: 0.5 * rowHeight, count: 2)
    press(x: 20, y: 4.5 * rowHeight, count: 1)
    XCTAssertEqual(hosted.source.clicks, ["click 2 x13", "double 0 x150"])
  }

  // MARK: - 送り

  /// 2 通りの送り: 最小限（見えるところまで）と中央へ。どちらも見えている行では動かない。
  func testTheTwoWaysToRevealARow() {
    let hosted = host()
    let list = hosted.list
    list.reveal(3, .nearest)
    list.reveal(3, .center)
    XCTAssertEqual(list.visibleRect.minY, 0, "見えている行では動かない")

    list.reveal(10, .nearest)
    XCTAssertEqual(list.visibleRect.maxY, 11 * rowHeight, accuracy: 0.5, "最小限: 行の下端が見える下端に")
    list.reveal(50, .center)
    XCTAssertEqual(list.visibleRect.midY, 50.5 * rowHeight, accuracy: 0.5, "中央へ")
    list.reveal(199, .center)
    XCTAssertEqual(list.visibleRect.maxY, list.frame.height, accuracy: 0.5, "端では寄せ切らない")
    list.reveal(0, .center)
    XCTAssertEqual(list.visibleRect.minY, 0)
  }

  /// 大きさが決まる前（SwiftUI の最初の更新）に変わった選択は、大きさが付いてから見せる——大きさの無いまま送った位置が
  /// 残ると、選択の行が上端で半分隠れる。
  func testASelectionRevealedBeforeTheListHasASizeIsShownOnceItDoes() {
    for (selection, check) in [(50, "中央へ"), (0, "先頭の行は欠けない")] {
      let source = Source()
      let rows = RowList(source: source, rowHeight: rowHeight)
      rows.update(
        rowsVersion: 0, selection: selection, reveal: .center, emoji: nil, wantsFocus: false)
      rows.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
      rows.tile()
      if selection == 0 {
        XCTAssertEqual(rows.list.visibleRect.minY, 0, check)
      } else {
        XCTAssertEqual(
          rows.list.visibleRect.midY, (CGFloat(selection) + 0.5) * rowHeight, accuracy: 0.5, check)
      }
    }
  }

  /// 選択の行を写し、選択が変わったときだけ、渡されたやり方で見せる。同じ選択のまま行がずれても・版が変わっても送らない。
  func testTheSelectionIsMirroredAndRevealedOnlyWhenItChanges() {
    let hosted = host()
    let list = hosted.list
    hosted.rows.update(
      rowsVersion: 0, selection: 50, reveal: .center, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.selectedRow, 50)
    XCTAssertEqual(list.visibleRect.midY, 50.5 * rowHeight, accuracy: 0.5, "変わった選択を中央へ")
    XCTAssertEqual(slots(list).filter(\.isSelected).map(\.row), [50], "選択の枠だけが選択")

    list.scrollToBeginningOfDocument(nil)
    hosted.rows.update(
      rowsVersion: 1, selection: 50, reveal: .center, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.visibleRect.minY, 0, "同じ選択では送らない")

    hosted.rows.update(
      rowsVersion: 1, selection: 60, reveal: .nearest, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.visibleRect.maxY, 61 * rowHeight, accuracy: 0.5, "変わった選択を最小限に")
    hosted.rows.update(
      rowsVersion: 1, selection: nil, reveal: .nearest, emoji: nil, wantsFocus: false)
    XCTAssertNil(list.selectedRow)
    XCTAssertTrue(slots(list).allSatisfy { !$0.isSelected })
  }

  // MARK: - 焦点

  /// 焦点の要求は列が窓の中で当てて源へ返し、焦点の出入りを源へ知らせる。
  func testTheFocusRequestIsAppliedAndTheFocusIsReported() {
    let hosted = host()
    hosted.source.wantsFocus = true
    hosted.rows.update(
      rowsVersion: 0, selection: nil, reveal: .nearest, emoji: nil, wantsFocus: true)
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
      rowsVersion: 0, selection: 2, reveal: .nearest, emoji: nil, wantsFocus: false)
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

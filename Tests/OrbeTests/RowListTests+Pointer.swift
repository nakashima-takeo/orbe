import AppKit
import XCTest

@testable import Orbe

/// ポインタの下の行——読み直しでも説明（ツールチップ）がポインタの下の今の部品に合い、ポインタが列の外に居る間はどの道
/// （読み直し・錨・送り）でもホバーを付けない。ポインタの位置は窓が答える値を差し替えて置く（本物のポインタを動かさない）。
///
/// 壊れると何が起きるか。見出しの一括操作を押した後、同じ位置に来た別の部品の上で前の部品の説明が出たままになる。
/// アプリが背後にある間や、ポインタが列を出た後に行が読み直されると、ポインタの無い行にホバーの地が付く。
extension RowListTests {
  /// ポインタの位置を差し替えられる窓。
  final class PointerWindow: NSWindow {
    var pointer = NSPoint.zero
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
  }

  /// 幅 200・高さ 100 の列を、ポインタを差し替えられる窓に載せる。ポインタは行 2 の部品の上。
  private func hostUnderThePointer() -> (Hosted, PointerWindow) {
    let source = Source()
    source.rowCount = 10
    let rows = RowList(source: source, rowHeight: rowHeight)
    let window = PointerWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = rows
    rows.update(rowsVersion: 0, selection: nil, emoji: nil, wantsFocus: false)
    rows.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let hosted = Hosted(source: source, rows: rows, window: window)
    window.pointer = hosted.list.convert(NSPoint(x: 185, y: 50), to: nil)
    return (hosted, window)
  }

  private func move(_ hosted: Hosted, to point: NSPoint) {
    hosted.rows.mouseMoved(with: .mouse(.mouseMoved, at: point, in: hosted.window))
  }

  private func hovered(_ hosted: Hosted) -> [Int] {
    slots(hosted.list).filter { $0.pointer != nil }.compactMap(\.row)
  }

  /// 行の数が変わらない読み直しの後、ポインタを動かさなくても、説明がポインタの下の今の部品のものになる。
  func testTheHelpFollowsTheRowsUnderAStillPointer() {
    let (hosted, window) = hostUnderThePointer()
    move(hosted, to: window.pointer)
    XCTAssertEqual(hosted.list.toolTip, "row 2")
    hosted.source.label = "next"
    hosted.rows.update(rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(hosted.list.toolTip, "next 2")
    XCTAssertEqual(hovered(hosted), [2])
  }

  /// ポインタが列を出た後は、窓が答える位置が列の上でも（アプリが背後にある間など）、読み直し・錨・送りのどれでもホバーを
  /// 付けない。押せば列の中に戻る。
  func testOutsideTheListNoPathPutsTheHoverBack() {
    let (hosted, window) = hostUnderThePointer()
    move(hosted, to: window.pointer)
    move(hosted, to: NSPoint(x: 100, y: 300))
    XCTAssertEqual(hovered(hosted), [], "前提: 出た")

    hosted.rows.update(rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(hovered(hosted), [], "読み直し")
    XCTAssertNil(hosted.list.toolTip)
    scroll(hosted, by: 20)
    XCTAssertEqual(hovered(hosted), [], "送り")
    hosted.list.holdAnchor()
    XCTAssertEqual(hovered(hosted), [], "錨")

    hosted.source.anchor = RowListAnchor(pressed: 3, successor: 4)
    press(hosted, at: hosted.list.convert(window.pointer, from: nil))
    hosted.rows.update(rowsVersion: 2, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(hovered(hosted), [3], "押せば列の中")
  }
}

import AppKit
import XCTest

@testable import Orbe

/// 列の頭（`RowListHeader`）——最初の行の上に置き、行と一緒に送る 1 枚の view。行の位置・押下・選択を見せる送りは頭の高さ
/// だけずれ、頭の高さが中身や幅で変わると行を置き直す。
///
/// 壊れると何が起きるか: 頭の下の行を押すと別の行が開く。頭を押すと、その下に隠れた行のクリックになる。選んだ行が頭の
/// 高さぶん欠けて見える。頭の中身や列の幅が変わると、頭と行が重なるか、読んでいた行が画面から跳ぶ。行の部品を押した
/// 直後に頭の高さが変わると、続けて同じ位置を押したときに別の行の部品に当たる。VoiceOver で頭の中身に辿れない。
extension RowListTests {
  /// 高さが幅で決まる頭の偽物——`text` 文字を 1 行 20 文字で折り返し、1 行 10pt。幅 100 で 1 行 20 文字。
  final class Header: NSView, RowListHeader {
    var text = 60
    func height(fitting width: CGFloat) -> CGFloat {
      let perLine = max(1, Int(width / 5))
      return CGFloat((text + perLine - 1) / perLine) * 10
    }
  }

  /// 幅 200 では 1 行 40 文字なので、60 文字の頭は 2 行で 20pt。
  private func hostWithHeader() -> (Hosted, Header) {
    let hosted = host()
    let header = Header()
    hosted.rows.setHeader(header)
    hosted.rows.layoutSubtreeIfNeeded()
    return (hosted, header)
  }

  /// 頭は列の幅いっぱいで先頭に置かれ、行は頭の下から並ぶ。列の高さは頭の分だけ増える。
  func testRowsStartBelowTheHeader() {
    let (hosted, header) = hostWithHeader()
    let list = hosted.list
    XCTAssertEqual(header.frame, NSRect(x: 0, y: 0, width: 200, height: 20))
    XCTAssertEqual(slot(list, 0)?.frame.minY, 20, "最初の行は頭の下")
    XCTAssertEqual(list.frame.height, 20 + rowHeight * 201, "頭＋行の数ぶん＋最後の行の下の空き")
    XCTAssertEqual(slot(list, 3)?.label, "row 3")
    XCTAssertNil(slot(list, 4), "見えている高さから頭の分だけ行が減る")
    XCTAssertTrue(list.accessibilityChildren()?.first as? Header === header, "VoiceOver は頭から辿る")
  }

  /// 押した位置は頭の高さを引いて行に換える。頭の範囲の押下は行のクリックにならない。
  func testPressesBelowTheHeaderReachTheRowUnderThePointer() {
    let (hosted, _) = hostWithHeader()
    press(hosted, at: NSPoint(x: 10, y: 20 + rowHeight * 2 + 5))
    press(hosted, at: NSPoint(x: 10, y: 15))
    XCTAssertEqual(hosted.source.clicks, ["click 2"])
  }

  /// 選択を見せる送りは、頭の下に並ぶ行の位置で決まる——選んだ行が下端で欠けない。
  func testTheRevealedSelectionAccountsForTheHeader() {
    let (hosted, _) = hostWithHeader()
    hosted.rows.update(rowsVersion: 0, selection: 50, emoji: nil, wantsFocus: false)
    XCTAssertEqual(
      hosted.list.visibleRect.maxY, 20 + CGFloat(51) * rowHeight, accuracy: 0.5,
      "行 50 の下端が見えている範囲の下端")
  }

  /// 頭の中身が変わって高さが変われば、行を置き直す。頭が少しでも見えていれば送らず（行が頭の下に付いて動く）、頭が
  /// 見えなくなるまで送っていれば、高さの差だけ送って見えている行を画面の同じ位置に残す。
  func testAHeaderHeightChangeMovesTheRowsButKeepsTheReadRowsInPlace() {
    let (hosted, header) = hostWithHeader()
    let list = hosted.list
    scroll(hosted, by: 5)
    header.text = 20
    hosted.rows.headerDidChange()
    XCTAssertEqual(header.frame.height, 10)
    XCTAssertEqual(slot(list, 0)?.frame.minY, 10, "頭が見えていれば、行は頭の下に付いて上がる")
    XCTAssertEqual(list.visibleRect.minY, 5, "頭が少し見えている間は送らない")

    scroll(hosted, by: 5 + rowHeight * 30)
    let read = list.convert(slot(list, 30)!.frame.origin, to: nil)
    header.text = 120
    hosted.rows.headerDidChange()
    XCTAssertEqual(header.frame.height, 30)
    XCTAssertEqual(
      list.convert(slot(list, 30)!.frame.origin, to: nil), read, "読んでいた行は画面の同じ位置")
  }

  /// 行の部品を押して行を留めている間に頭が高くなっても、押した行はポインタの下に留まる（頭が見えていても送る）。
  func testAHeaderHeightChangeKeepsThePressedRowUnderThePointer() throws {
    let (hosted, header) = hostWithHeader()
    let list = hosted.list
    hosted.source.anchor = RowListAnchor(pressed: 2, successor: 3)
    press(hosted, at: NSPoint(x: 190, y: 20 + rowHeight * 2 + 5))
    XCTAssertEqual(hosted.source.clicks, ["press 2 0"], "前提: 行 2 の部品")
    let pressed = list.convert(try XCTUnwrap(slot(list, 2)).frame.origin, to: nil)
    header.text = 120
    hosted.rows.headerDidChange()
    XCTAssertEqual(header.frame.height, 30)
    XCTAssertEqual(list.convert(try XCTUnwrap(slot(list, 2)).frame.origin, to: nil), pressed)
  }

  /// 列の幅が変われば頭の高さを測り直す。
  func testTheHeaderIsMeasuredAgainWhenTheWidthChanges() {
    let (hosted, header) = hostWithHeader()
    hosted.window.setContentSize(NSSize(width: 100, height: 100))
    hosted.rows.layoutSubtreeIfNeeded()
    XCTAssertEqual(header.frame, NSRect(x: 0, y: 0, width: 100, height: 30), "1 行 20 文字で 3 行")
    XCTAssertEqual(slot(hosted.list, 0)?.frame.minY, 30)
  }

  /// 頭を外せば、頭の無い列と同じ並びに戻る。
  func testRemovingTheHeaderRestoresThePlainList() {
    let (hosted, header) = hostWithHeader()
    hosted.rows.setHeader(nil)
    XCTAssertNil(header.superview)
    XCTAssertFalse(
      hosted.list.accessibilityChildren()?.contains { $0 as? Header === header } ?? false,
      "外した頭は VoiceOver の子に残らない")
    XCTAssertEqual(slot(hosted.list, 0)?.frame.minY, 0)
    XCTAssertEqual(hosted.list.frame.height, rowHeight * 201)
  }
}

import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 行の中の部品の押下——描いている組で渡すことと、錨（押した行をポインタの下に留め、一時の空きで収め、列を動かせば外す）。
///
/// 壊れると何が起きるか。行の組が差し替わる瞬間に押すと、見えていた行と別のファイルがステージ・破棄される。帯の出入りで
/// 列が動くと、同じ位置で続けて押したときに別の行に当たる。キー・ホイール・つまみ・列の外への移動の後も空きが残る。
extension RowListTests {
  /// 源の組が差し替わってから列が読み直すまでの間に部品を押しても、列が描いている組で渡す。
  func testAPressBeforeTheListReloadsIsPassedWithTheRowsItShows() {
    let hosted = host()
    hosted.source.version = 1
    press(hosted, at: NSPoint(x: 190, y: 50))
    XCTAssertEqual(hosted.source.clicks, ["press 2 0"])
    XCTAssertEqual(hosted.source.pressedVersions, [0], "描いている組")
  }

  /// 上の帯が出入りして列が窓の中で動き大きさが変わっても、押した行の上端は押したときの窓の高さに留まる（送れない分は
  /// 一時の空きで収める）。
  func testThePressedRowStaysUnderThePointerWhileABandAboveComesAndGoes() throws {
    let source = Source()
    source.rowCount = 40
    source.anchor = RowListAnchor(pressed: 5, successor: 6)
    let rows = RowList(source: source, rowHeight: rowHeight)
    let band = Band()
    band.isShown = true
    let host = NSHostingView(rootView: BandOverList(band: band, rows: rows))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let list = rows.list
    func top(of row: Int) throws -> CGFloat {
      let slot = try XCTUnwrap(slot(list, row), "行 \(row) が見えている")
      return list.convert(NSPoint(x: 0, y: slot.frame.minY), to: nil).y
    }
    let pressed = try top(of: 5)
    list.mouseDown(
      with: .mouse(
        .leftMouseDown, at: list.convert(NSPoint(x: 190, y: 110), to: nil), in: window))
    XCTAssertEqual(source.clicks, ["press 5 0"], "前提: 行 5 の部品")

    for isShown in [false, true] {
      band.isShown = isShown
      host.layoutSubtreeIfNeeded()
      XCTAssertEqual(
        try top(of: 5), pressed, accuracy: 0.5, isShown ? "帯が出る" : "帯が消える（先頭なので空きで収める）")
    }
  }

  /// 一時の空きは、キー・ホイール・つまみ・列の外へのポインタの移動で列を動かすと消える。
  func testTheTemporaryGapGoesAwayWhenTheListIsMovedByTheUser() {
    let triggers: [(String, (Hosted) -> Void)] = [
      ("キー", { $0.list.keyDown(with: self.key(.downArrow)) }),
      (
        "ホイール",
        { hosted in
          let wheel = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0,
            wheel3: 0)!
          hosted.rows.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        }
      ),
      (
        "つまみ",
        { hosted in
          let thumb = hosted.rows.scrollbar
          let grab = thumb.convert(NSPoint(x: thumb.bounds.midX, y: thumb.bounds.midY), to: nil)
          thumb.mouseDown(with: .mouse(.leftMouseDown, at: grab, in: hosted.window))
          thumb.mouseDragged(
            with: .mouse(
              .leftMouseDragged, at: NSPoint(x: grab.x, y: grab.y - 8), in: hosted.window))
        }
      ),
      (
        "列の外への移動",
        { hosted in
          hosted.rows.mouseMoved(
            with: .mouse(.mouseMoved, at: NSPoint(x: 100, y: 300), in: hosted.window))
        }
      ),
    ]
    for (name, move) in triggers {
      let hosted = hostWithATemporaryGap()
      move(hosted)
      XCTAssertEqual(hosted.list.frame.height, 10 + 200 + rowHeight, name)
    }
  }

  /// 錨の一時の空きがある間に選択を見せるときは、錨を外して空きを取った後の行の位置で送る——空きのぶん余計に送らない。
  func testRevealingASelectionUnderATemporaryGapScrollsByTheRowsPositionAfterTheGapIsGone() {
    let hosted = hostWithATemporaryGap()
    let list = hosted.list
    // 行 3 は空きのある間 100..<120 で見えていないが、空きを取れば 70..<90 で見えている。
    hosted.rows.update(rowsVersion: 1, selection: 3, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.frame.height, 10 + 200 + rowHeight, "錨を外して空きを取る")
    XCTAssertEqual(list.visibleRect.minY, 0, "空きを取った後に見えている行では送らない")
  }

  /// 行 2 の部品を押した後に上の余白が 40 から 10 に縮み、行 2 を押した高さに留めるため上に 30 の空きがある列。
  private func hostWithATemporaryGap() -> Hosted {
    let hosted = host(
      rowCount: 10, segments: [RowListSegment(start: 0, count: 10, height: 20, leading: 40)])
    let list = hosted.list
    hosted.source.anchor = RowListAnchor(pressed: 2, successor: 3)
    // 行 2 は 80..<100。
    press(hosted, at: NSPoint(x: 190, y: 85))
    // 余白が縮むと行 2 は 50 に上がり、上に 30 の空きを足して 80 に留める。
    hosted.source.segments = [RowListSegment(start: 0, count: 10, height: 20, leading: 10)]
    hosted.rows.update(rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.visibleRect.minY, 0, "前提: 空きで留めている")
    XCTAssertEqual(list.frame.height, 30 + 10 + 200 + rowHeight, "前提: 上に 30 の空き")
    return hosted
  }

  final class Band: ObservableObject {
    @Published var isShown = false
  }

  /// 高さ 28 の帯（出し入れできる）の下に、残りを埋める列。
  struct BandOverList: View {
    @ObservedObject var band: Band
    let rows: RowList<Source>

    var body: some View {
      VStack(spacing: 0) {
        if band.isShown { Color.clear.frame(height: 28) }
        RowListHost(list: rows, rowsVersion: 0, selection: nil, emoji: nil, wantsFocus: false)
      }
    }
  }
}

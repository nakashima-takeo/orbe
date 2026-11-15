import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 行の中の部品の押下——描いている組で渡すことと、錨（押した行をポインタの下に留め、上へは送れる分だけ・下は一時の空きで
/// 収め、留める行が無ければ原点を保ち、列を動かせば外す）。
///
/// 壊れると何が起きるか。行の組が差し替わる瞬間に押すと、見えていた行と別のファイルがステージ・破棄される。帯の出入りで
/// 列が動くと、同じ位置で続けて押したときに別の行に当たる。列の上に空きができて見出しごと下がってくる。区分の最後の行を
/// 処理した後に列が跳ぶ。キー・ホイール・つまみ・列の外への移動の後も空きが残る。選択を見せるために送っても錨が残り、
/// 次の読み直しで見せた選択が画面の外へ戻される。
extension RowListTests {
  /// 源の組が差し替わってから列が読み直すまでの間に部品を押しても、列が描いている組で渡す。
  func testAPressBeforeTheListReloadsIsPassedWithTheRowsItShows() {
    let hosted = host()
    hosted.source.version = 1
    press(hosted, at: NSPoint(x: 190, y: 50))
    XCTAssertEqual(hosted.source.clicks, ["press 2 0"])
    XCTAssertEqual(hosted.source.pressedVersions, [0], "描いている組")
  }

  /// 上の帯が出入りして列が窓の中で動き大きさが変わっても、上へ送れる間は、押した行の上端は押したときの窓の高さに留まる。
  func testThePressedRowStaysUnderThePointerWhileABandAboveComesAndGoes() throws {
    let banded = try hostUnderABand(scrolledBy: 100)
    banded.source.anchor = RowListAnchor(pressed: 10, successor: 11)
    let pressed = try banded.top(10)
    banded.press(at: 210)
    XCTAssertEqual(banded.source.clicks, ["press 10 0"], "前提: 行 10 の部品")

    for isShown in [false, true] {
      banded.band.isShown = isShown
      banded.host.layoutSubtreeIfNeeded()
      XCTAssertEqual(try banded.top(10), pressed, accuracy: 0.5, isShown ? "帯が出る" : "帯が消える")
    }
  }

  /// 列の上に空きは作らない——原点が 0 で上の帯が消えると、押した行は留まらずに上がり、文書の高さは行と末尾の空きだけ。
  func testTheListMakesNoGapAboveWhenItCannotScrollUp() throws {
    let banded = try hostUnderABand(scrolledBy: 0)
    banded.source.anchor = RowListAnchor(pressed: 5, successor: 6)
    let pressed = try banded.top(5)
    banded.press(at: 110)
    banded.band.isShown = false
    banded.host.layoutSubtreeIfNeeded()
    XCTAssertEqual(try banded.top(5), pressed + 28, accuracy: 0.5, "帯のぶん上がる（窓の座標は上が正）")
    XCTAssertEqual(banded.rows.list.visibleRect.minY, 0)
    XCTAssertEqual(banded.rows.list.frame.height, 40 * rowHeight + rowHeight, "上の空きは無い")
  }

  /// 留める行が組に無い（後継なしの錨で押した行が抜けた）ときは、今の原点を保つ——文書が縮んでも下の空きで収め、手の下で
  /// 列を跳ばさない。
  func testWithoutARowToHoldTheListKeepsItsOrigin() {
    let hosted = host(rowCount: 10)
    scroll(hosted, by: 40)
    hosted.source.anchor = RowListAnchor(pressed: 4, successor: nil)
    press(hosted, at: NSPoint(x: 190, y: 85))
    hosted.source.rowCount = 4
    hosted.rows.update(rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(hosted.list.visibleRect.minY, 40, "原点を保つ")
    XCTAssertEqual(hosted.list.frame.height, 40 + 100, "下の空きで収める")
  }

  /// 一時の空きは、キー・ホイール・つまみ・列の外へのポインタの移動・選択を見せるための送りで列を動かすと消える。
  func testTheTemporaryGapGoesAwayWhenTheListIsMoved() {
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
      // 行 3 は見えている 120..<220 の外。
      ("選択を見せる", { $0.rows.update(rowsVersion: 1, selection: 3, emoji: nil, wantsFocus: false) }),
    ]
    for (name, move) in triggers {
      let hosted = hostWithABottomGap()
      move(hosted)
      XCTAssertEqual(hosted.list.frame.height, 9 * rowHeight + rowHeight, name)
    }
  }

  /// 10 行の列を末尾まで送り、行 8 の部品を押した後に行が 1 つ減って、行 8（の位置に来た行）を押した高さに留めるため下に
  /// 20 の空きがある列。
  private func hostWithABottomGap() -> Hosted {
    let hosted = host(rowCount: 10)
    let list = hosted.list
    scroll(hosted, by: 120)
    hosted.source.anchor = RowListAnchor(pressed: 8, successor: 9)
    // 行 8 は 160..<180。
    press(hosted, at: NSPoint(x: 190, y: 165))
    hosted.source.rowCount = 9
    hosted.rows.update(rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(list.visibleRect.minY, 120, "前提: 行 8 を留めている")
    XCTAssertEqual(list.frame.height, 9 * rowHeight + rowHeight + 20, "前提: 下に 20 の空き")
    return hosted
  }

  struct Banded {
    let source: Source
    let rows: RowList<Source>
    let band: Band
    let host: NSView
    let window: NSWindow

    /// 行 `row` の上端（窓の座標）。
    @MainActor func top(_ row: Int) throws -> CGFloat {
      let list = rows.list
      let slot = try XCTUnwrap(
        list.subviews.compactMap { $0 as? Row }.first { $0.row == row && !$0.isHidden },
        "行 \(row) が見えている")
      return list.convert(NSPoint(x: 0, y: slot.frame.minY), to: nil).y
    }

    /// 列の文書の高さ `y` の行の部品を押す。
    @MainActor func press(at y: CGFloat) {
      let list = rows.list
      list.mouseDown(
        with: .mouse(.leftMouseDown, at: list.convert(NSPoint(x: 190, y: y), to: nil), in: window))
    }
  }

  /// 高さ 28 の帯（出ている）の下に 40 行の列を載せ、`offset` だけ送った状態で返す。
  private func hostUnderABand(scrolledBy offset: CGFloat) throws -> Banded {
    let source = Source()
    source.rowCount = 40
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
    let clip = rows.contentView
    clip.scroll(to: NSPoint(x: 0, y: offset))
    rows.reflectScrolledClipView(clip)
    return Banded(source: source, rows: rows, band: band, host: host, window: window)
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

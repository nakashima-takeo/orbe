import AppKit
import XCTest

@testable import Orbe

/// 押し続けの守り——部品を押して錨を受け取った後、ポインタが押した部品の枠の中に居る間は、その枠の中の押下が留めている
/// 行の同じ部品にだけ届く。押下はアプリの配送の口（`NSApp.sendEvent`）から送り、窓の段の受け手も本物と同じく通す（窓は
/// 物理画面の外へ並べる。`sendEvent` は ordered-in の窓にしか配送しない）。
///
/// 壊れると何が起きるか。続けて押している位置に留めきれずに来た見出し・別の区分の行・列の外のもの（帯の出入りで来た
/// コミットボタン）が、続けて押すつもりの押下で働く（開閉・すべてステージ・別のファイルのステージ・コミット）。守りが
/// 終わらずに、枠を出た後の押下やキーの後の押下まで食われる。
extension RowListTests {
  /// 窓に載せて並べた列（`host` と同じ大きさ）。部品の押下に `anchor` を返す。
  private func hostShown(anchor: RowListAnchor<Int>?) -> Hosted {
    let hosted = host(rowCount: 10)
    hosted.source.anchor = anchor
    hosted.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    hosted.window.orderFront(nil)
    return hosted
  }

  /// 列の座標 `point` に、アプリの配送の口から `type` を送る。
  private func send(_ type: NSEvent.EventType, _ hosted: Hosted, at point: NSPoint) {
    NSApp.sendEvent(.mouse(type, at: hosted.list.convert(point, to: nil), in: hosted.window))
  }

  /// 行 2 の部品（列の座標）。
  private var control: NSPoint { NSPoint(x: 185, y: 50) }

  /// 留める行がある間、枠の中の押下はその行の同じ部品に届く。
  func testWhileHoldingThePressReachesTheSameControlOfTheHeldRow() {
    let hosted = hostShown(anchor: RowListAnchor(pressed: 2, successor: 3))
    send(.leftMouseDown, hosted, at: control)
    send(.leftMouseDown, hosted, at: control)
    XCTAssertEqual(hosted.source.clicks, ["press 2 0", "press 2 0"])
  }

  /// 留める行がポインタの下に来ていなければ（上へ送れずに留めきれない）、枠の中の押下は捨てる——来た別の行の同じ部品も
  /// 働かない。
  func testWhenTheHeldRowIsNotUnderThePointerPressesInsideTheControlAreDropped() {
    // 押した行 2 が抜け、後継は 1 つ上の行 1。原点 0 の列は行 1 を押した高さへ下ろせない。
    let hosted = hostShown(anchor: RowListAnchor(pressed: 99, successor: 1))
    send(.leftMouseDown, hosted, at: control)
    hosted.rows.update(rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(hosted.list.visibleRect.minY, 0, "前提: 留めきれずに原点のまま")
    send(.leftMouseDown, hosted, at: control)
    XCTAssertEqual(hosted.source.clicks, ["press 2 0"], "ポインタの下の行 2 の部品は働かない")
  }

  /// 留める行が無ければ、枠の中の押下は捨てる。枠の外へ動く・枠の外を押す・キーで守りは終わり、そこからは普通に届く。
  func testWithoutAHeldRowPressesInsideTheControlAreDroppedUntilTheGuardEnds() {
    let hosted = hostShown(anchor: RowListAnchor(pressed: 99, successor: nil))
    send(.leftMouseDown, hosted, at: control)
    send(.leftMouseDown, hosted, at: control)
    XCTAssertEqual(hosted.source.clicks, ["press 2 0"], "留める行が無ければ捨てる")
    send(.mouseMoved, hosted, at: NSPoint(x: control.x + 3, y: control.y + 3))
    send(.leftMouseDown, hosted, at: control)
    XCTAssertEqual(hosted.source.clicks, ["press 2 0"], "枠の中で動いても守りのまま")

    send(.mouseMoved, hosted, at: NSPoint(x: 100, y: control.y))
    send(.leftMouseDown, hosted, at: control)
    XCTAssertEqual(hosted.source.clicks.count, 2, "枠の外へ動けば終わる")
    send(.leftMouseDown, hosted, at: NSPoint(x: 20, y: control.y))
    send(.leftMouseDown, hosted, at: control)
    XCTAssertEqual(hosted.source.clicks.suffix(2), ["click 2", "press 2 0"], "枠の外を押せば終わる")
    NSApp.sendEvent(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: hosted.window.windowNumber, context: nil, characters: "a",
        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!)
    send(.leftMouseDown, hosted, at: control)
    XCTAssertEqual(hosted.source.clicks.last, "press 2 0", "キーで終わる")
    XCTAssertEqual(hosted.source.clicks.count, 5)
  }

  /// 守りの中で押せない姿の部品を押しても、源へは渡らず、留め（一時の空き・原点）も守りも変わらない——枠の中に来た列の外の
  /// view への押下は、続けて捨てる。
  func testAPressOnADisabledControlKeepsTheHoldAndTheGuard() {
    let hosted = host(rowCount: 3)
    hosted.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    hosted.window.orderFront(nil)
    // 押した行 1 が抜け、後継の行 2 を行 1 の高さ（窓の中の 20）に留める。
    hosted.source.anchor = RowListAnchor(pressed: 99, successor: 2)
    let point = NSPoint(x: 185, y: 30)
    send(.leftMouseDown, hosted, at: point)
    hosted.rows.update(rowsVersion: 1, selection: nil, emoji: nil, wantsFocus: false)
    XCTAssertEqual(hosted.list.visibleRect.minY, 20, "前提: 行 2 を留めている")
    XCTAssertEqual(hosted.list.frame.height, 120, "前提: 下に 40 の空き")

    hosted.source.disabledRows = [2]
    hosted.rows.update(rowsVersion: 2, selection: nil, emoji: nil, wantsFocus: false)
    let held = NSPoint(x: point.x, y: point.y + 20)
    send(.leftMouseDown, hosted, at: held)
    XCTAssertEqual(hosted.source.clicks, ["press 1 0"], "押せない部品は源へ渡らない")
    XCTAssertEqual(hosted.list.visibleRect.minY, 20, "原点を保つ")
    XCTAssertEqual(hosted.list.frame.height, 120, "空きを保つ")

    let spot = hosted.list.convert(held, to: nil)
    let local = hosted.rows.convert(spot, from: nil)
    let catcher = Catcher(frame: NSRect(x: local.x - 20, y: local.y - 20, width: 40, height: 40))
    hosted.rows.addSubview(catcher)
    NSApp.sendEvent(.mouse(.leftMouseDown, at: spot, in: hosted.window))
    XCTAssertEqual(catcher.downs, 0, "守りは続く")
  }

  /// 守りは窓の段で押下を受ける——列が動いて枠の中に列の外の view が来ても、その押下はどこにも届かない。
  func testTheGuardDropsAPressOnAViewThatCameUnderThePointer() {
    let hosted = hostShown(anchor: RowListAnchor(pressed: 2, successor: 3))
    send(.leftMouseDown, hosted, at: control)
    let spot = hosted.list.convert(control, to: nil)
    let catcher = Catcher(frame: NSRect(x: spot.x - 20, y: spot.y - 20, width: 40, height: 40))
    hosted.rows.addSubview(catcher)
    NSApp.sendEvent(.mouse(.leftMouseDown, at: spot, in: hosted.window))
    XCTAssertEqual(catcher.downs, 0, "列の外の view に届かない")
    XCTAssertEqual(hosted.source.clicks, ["press 2 0"])
    NSApp.sendEvent(.mouse(.mouseMoved, at: NSPoint(x: 10, y: 10), in: hosted.window))
    NSApp.sendEvent(.mouse(.leftMouseDown, at: spot, in: hosted.window))
    XCTAssertEqual(catcher.downs, 1, "守りが終われば届く")
  }

  /// 押下を数える view。
  final class Catcher: NSView {
    private(set) var downs = 0
    override func mouseDown(with event: NSEvent) { downs += 1 }
  }
}

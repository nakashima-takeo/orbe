import AppKit
import XCTest

@testable import Orbe

/// 取っ手を離す・押すときの判定——離す直前の勢いだけが閉じるかを決め、位置のばねが動いている途中で掴めば止まって手に渡る。
///
/// 壊れると何が起きるか。勢いを測る窓が効かないと、端の近くへ素早く寄せて止めてから離しただけで面が閉じ、勢いが器へ
/// 届かないと端へ投げても閉じない。滑っている途中で掴んで離すと、その場に置いたつもりが反対の全面へ飛び、形がまだ追って
/// いるだけの離した直後に押すと、押しても何も起きない。
extension TabFacesViewTests {
  /// 取っ手へ、窓の x と時刻（秒）を持つマウスの出来事を届ける。
  private func send(
    _ type: NSEvent.EventType, x: CGFloat, at time: TimeInterval, to handle: FaceHandleView
  ) {
    let event = NSEvent.mouseEvent(
      with: type, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: time,
      windowNumber: handle.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
      clickCount: 1, pressure: 1)!
    switch type {
    case .leftMouseDown: handle.mouseDown(with: event)
    case .leftMouseDragged: handle.mouseDragged(with: event)
    default: handle.mouseUp(with: event)
    }
  }

  /// 継ぎ目を端へ向けて投げて離すと、離した位置が端から遠くても、その勢いで面が閉じる。
  func testFlingTowardTheEdgeClosesTheFace() {
    let (tab, _) = hostedInWindow(FaceLayout(editorRatio: 0.5, focus: .terminal))
    let handle = tab.view.handle

    send(.leftMouseDown, x: 506, at: 10.00, to: handle)
    send(.leftMouseDragged, x: 406, at: 10.01, to: handle)
    send(.leftMouseDragged, x: 306, at: 10.02, to: handle)
    send(.leftMouseDragged, x: 206, at: 10.03, to: handle)
    send(.leftMouseUp, x: 206, at: 10.04, to: handle)

    XCTAssertEqual(tab.faces, .terminalOnly, "左へ投げたエディターは閉じる")
  }

  /// 端の近くへ素早く寄せても、止めてから離せば勢いは残らず、離した位置で分割として残る。
  func testReleaseAfterStoppingNearTheEdgeKeepsTheSplit() {
    let (tab, _) = hostedInWindow(.terminalOnly)
    let handle = tab.view.handle

    send(.leftMouseDown, x: 6, at: 10.00, to: handle)
    send(.leftMouseDragged, x: 206, at: 10.01, to: handle)
    send(.leftMouseDragged, x: 106, at: 10.02, to: handle)
    send(.leftMouseDragged, x: 46, at: 10.03, to: handle)
    send(.leftMouseUp, x: 46, at: 10.30, to: handle)

    XCTAssertEqual(
      tab.faces, FaceLayout(editorRatio: 0.04, focus: .terminal), "止まる前の勢いで閉じず、離した位置に残る")
  }

  /// 位置のばねで滑っている途中で掴むと、境はその場で止まり中身の寸法も変わらない。動かさずに離せば、その位置で離した
  /// ことになり、分割として残る（押した扱いで反対の全面へ飛ばない）。
  func testGrabWhileSlidingStopsInPlaceAndReleasesThere() {
    let (tab, _) = hostedInWindow(.terminalOnly)
    let view = tab.view
    let handle = view.handle
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: true)
    var frames = 0
    while handle.frame.minX < 300, frames < 600 {
      view.tick(dt: 1.0 / 120)
      frames += 1
    }
    let grabbed = handle.frame.minX
    XCTAssertLessThan(grabbed, 1000, "前提: 滑っている途中")

    send(.leftMouseDown, x: handle.frame.midX, at: 10.00, to: handle)
    let editorSize = view.editor.frame.size
    let terminalSize = tab.surface.bounds.size
    for _ in 0..<30 { view.tick(dt: 1.0 / 120) }
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(handle.frame.minX, grabbed, "掴んだところで止まる")
    XCTAssertEqual(view.editor.frame.size, editorSize, "掴んだだけでエディターの寸法は変わらない")
    XCTAssertEqual(tab.surface.bounds.size, terminalSize, "掴んだだけで端末の寸法は変わらない")

    send(.leftMouseUp, x: handle.frame.midX, at: 10.50, to: handle)
    XCTAssertEqual(tab.faces.focus, .editor)
    XCTAssertEqual(tab.faces.editorRatio, Double(grabbed / 1000), accuracy: 0.001, "その位置で分割として残る")
  }

  /// 離して分割に残した直後、形がまだ位置を追っている間に押しても、押した扱いで焦点の側の全面になる。
  func testClickRightAfterReleaseExpandsTheFocusedFace() {
    let (tab, _) = hostedInWindow(.terminalOnly)
    let view = tab.view
    let handle = view.handle
    send(.leftMouseDown, x: 6, at: 10.00, to: handle)
    send(.leftMouseDragged, x: 306, at: 10.01, to: handle)
    send(.leftMouseUp, x: 306, at: 10.30, to: handle)
    XCTAssertEqual(tab.faces, FaceLayout(editorRatio: 0.3, focus: .terminal), "前提: 分割に残った")
    XCTAssertTrue(view.isAnimating, "前提: 形がまだ追っている")

    send(.leftMouseDown, x: handle.frame.midX, at: 10.31, to: handle)
    send(.leftMouseUp, x: handle.frame.midX, at: 10.32, to: handle)

    XCTAssertEqual(tab.faces, .terminalOnly, "焦点の側（端末）が全面になる")
  }
}

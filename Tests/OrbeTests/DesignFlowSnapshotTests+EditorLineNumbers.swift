import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorText

/// 行番号の列の flow（fixture は gallery と同じ `EditorCodeFixtures`）。番号のクリックで行を選び、ドラッグで下へ・上へ
/// 行単位に伸ばし、⇧クリックで起点から伸ばす過程と、横スクロールしても本文が行番号の列の下をくぐらないことを撮る。
extension DesignFlowSnapshotTests {
  func testEditorLineSelect() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorCodeFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    let document = scene.document
    let column = try XCTUnwrap(document.surface.view.subviews.last as? LineNumbersView)
    let scroll = try XCTUnwrap(document.surface.view.subviews.first as? NSScrollView)
    let style = EditorStyle.make()
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    pumpMain(until: { scene.isReady }, "index 版が届く")
    func mouse(_ type: NSEvent.EventType, row: CGFloat, _ flags: NSEvent.ModifierFlags = [])
      -> NSEvent
    {
      let point = NSPoint(x: 20, y: column.bounds.minY + (row - 0.5) * style.lineHeight)
      return NSEvent.mouseEvent(
        with: type, location: column.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
        windowNumber: column.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1)!
    }
    try flow(
      "editor_line_select", size: NSSize(width: 1000, height: 480), render: { scene.view },
      steps: [
        ("open", {}),
        (
          "click_line_3",
          {  // 番号を押すと 3 行目を改行まで選ぶ
            column.mouseDown(with: mouse(.leftMouseDown, row: 3))
            column.mouseUp(with: mouse(.leftMouseUp, row: 3))
          }
        ),
        (
          "drag_down_to_line_7",
          {  // 押した 3 行目を起点に、7 行目の終わりまで伸びる
            column.mouseDown(with: mouse(.leftMouseDown, row: 3))
            column.mouseDragged(with: mouse(.leftMouseDragged, row: 7))
            column.mouseUp(with: mouse(.leftMouseUp, row: 7))
          }
        ),
        (
          "drag_up_to_line_2",
          {  // 6 行目から上へ: 2 行目の頭から 6 行目の終わりまで（動く側は先頭）
            column.mouseDown(with: mouse(.leftMouseDown, row: 6))
            column.mouseDragged(with: mouse(.leftMouseDragged, row: 2))
            column.mouseUp(with: mouse(.leftMouseUp, row: 2))
          }
        ),
        (
          "shift_click_line_11",
          {  // 直前に選んだ 6 行目が起点のまま、11 行目の終わりまで伸びる
            column.mouseDown(with: mouse(.leftMouseDown, row: 11, .shift))
            column.mouseUp(with: mouse(.leftMouseUp, row: 11, .shift))
          }
        ),
        (
          "scrolled_right",
          {  // 20 桁ぶん右へ: 本文と選択の地は動き、行番号の列は本文の左に並んだまま
            scroll.contentView.scroll(to: NSPoint(x: 20 * cell, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
          }
        ),
      ])
  }
}

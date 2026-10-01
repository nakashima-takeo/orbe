import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 行番号の列の flow（fixture は gallery と同じ `EditorCodeFixtures`）。番号のクリックで行を選び、ドラッグで下へ・上へ
/// 行単位に伸ばし、⇧クリックで起点から伸ばす過程と、横スクロールしても本文が行番号の列の下をくぐらないことを撮る。
extension DesignFlowSnapshotTests {
  func testEditorLineSelect() throws {
    let scene = try codeScene()
    defer { scene.cleanup() }
    let surface = try surface(scene.document)
    let view = surface.view
    let config = surface.config
    pumpMain(until: { scene.isReady }, "index 版が届く")
    func mouse(_ type: NSEvent.EventType, row: CGFloat, _ flags: NSEvent.ModifierFlags = [])
      -> NSEvent
    {
      let point = NSPoint(x: 20, y: config.topInset + (row - 0.5) * config.lineHeight)
      return NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1)!
    }
    try hostedFlow(
      "editor_line_select", scene,
      steps: [
        ("open", {}),
        (
          "click_line_3",
          {  // 番号を押すと 3 行目を改行まで選ぶ
            view.mouseDown(with: mouse(.leftMouseDown, row: 3))
            view.mouseUp(with: mouse(.leftMouseUp, row: 3))
          }
        ),
        (
          "drag_down_to_line_7",
          {  // 押した 3 行目を起点に、7 行目の終わりまで伸びる
            view.mouseDown(with: mouse(.leftMouseDown, row: 3))
            view.mouseDragged(with: mouse(.leftMouseDragged, row: 7))
            view.mouseUp(with: mouse(.leftMouseUp, row: 7))
          }
        ),
        (
          "drag_up_to_line_2",
          {  // 6 行目から上へ: 2 行目の頭から 6 行目の終わりまで（動く側は先頭）
            view.mouseDown(with: mouse(.leftMouseDown, row: 6))
            view.mouseDragged(with: mouse(.leftMouseDragged, row: 2))
            view.mouseUp(with: mouse(.leftMouseUp, row: 2))
          }
        ),
        (
          "shift_click_line_11",
          {  // 直前に選んだ 6 行目が起点のまま、11 行目の終わりまで伸びる
            view.mouseDown(with: mouse(.leftMouseDown, row: 11, .shift))
            view.mouseUp(with: mouse(.leftMouseUp, row: 11, .shift))
          }
        ),
        (
          "scrolled_right",
          {  // 20 桁ぶん右へ: 本文と選択の地は動き、行番号の列は本文の左に並んだまま
            surface.scroll(toX: 20 * config.cell)
            self.settleFades(scene.pane)
          }
        ),
      ])
  }
}

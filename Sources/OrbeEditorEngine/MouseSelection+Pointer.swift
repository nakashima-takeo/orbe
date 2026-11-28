import AppKit
import OrbeEditorCore

extension MouseSelection {
  /// ポインタの形と URL の下線——行番号と印の列は矢印、本文は I ビーム、⌘ を押して URL の上なら指（面に焦点があるとき）。
  /// 絵の差し込みの押せる場所は載せる側が決めた形、行の頭の印は指、絵の差し込みの入力欄・選べる文・ほかに当たらない所は
  /// I ビーム。
  /// ⌘ を押している間は、面に焦点があれば本文の上のポインタの位置を面へ渡し、下線はその位置の下の URL に描画スレッドが
  /// そのコマの配置で引く（指カーソル・⌘クリックと同じ、面の焦点の判定）。スクロールで URL の矩形が動くので、矩形は登録せずその場の当たりで決める。
  func updatePointer(at windowPoint: NSPoint, flags: NSEvent.ModifierFlags, in view: NSView) {
    guard let surface else { return }
    let point = view.convert(windowPoint, from: nil)
    if view.bounds.contains(point) {
      switch surface.target(at: point) {
      case .body: break
      case .button(_, let button):
        surface.setLinkPointer(nil)
        return button.cursor.set()
      case .leadingMark:
        surface.setLinkPointer(nil)
        return NSCursor.pointingHand.set()
      case .field, .zoneText, .zoneSpace:
        surface.setLinkPointer(nil)
        return NSCursor.iBeam.set()
      }
    }
    let hit = view.bounds.contains(point) ? surface.hit(point) : nil
    let armed = flags.contains(.command) && hit?.area == .text
    surface.setLinkPointer(armed && surface.focused ? point : nil)
    guard let hit else { return }
    if hit.area != .text {
      NSCursor.arrow.set()
    } else if armed, surface.focused, surface.link(at: point) != nil {
      NSCursor.pointingHand.set()
    } else {
      NSCursor.iBeam.set()
    }
  }

  /// 押せる場所を押していたなら、離した点 `up`（view の座標）が同じものの上のときだけ押下を知らせる。行の頭の印を引いて
  /// いたなら、離した所に依らず範囲を知らせる。どちらかを押していたなら true。
  func releasePress(at up: CGPoint) -> Bool {
    guard let surface else { return false }
    switch drag {
    case .button(let press):
      guard case .button(let entry, let button) = surface.target(at: up),
        ObjectIdentifier(entry.zone) == press.zone, button.id == press.id
      else { return true }
      surface.transact { entry.zone.zone(.pressed(press.id)) }
      return true
    case .leadingMark:
      surface.finishLeadingMarkDrag()
      return true
    default:
      return false
    }
  }
}

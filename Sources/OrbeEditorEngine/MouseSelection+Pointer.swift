import AppKit
import OrbeEditorCore

extension MouseSelection {
  /// ポインタの形と URL の下線——行番号と印の列は矢印、本文は I ビーム、⌘ を押して URL の上なら指（面に焦点があるとき）。
  /// 区画の押せる場所は載せる側が決めた形、区画の入力欄・選べる文・空きは I ビーム。
  /// ⌘ を押している間は本文の上のポインタの位置を面へ渡し、下線はその位置の下の URL に描画スレッドがそのコマの配置で
  /// 引く。スクロールで URL の矩形が動くので、矩形は登録せずその場の当たりで決める。
  func updatePointer(at windowPoint: NSPoint, flags: NSEvent.ModifierFlags, in view: NSView) {
    guard let surface else { return }
    let point = view.convert(windowPoint, from: nil)
    if view.bounds.contains(point) {
      switch surface.target(at: point) {
      case .body: break
      case .button(_, let button):
        surface.setLinkPointer(nil)
        return button.cursor.set()
      case .field, .zoneText, .zoneSpace:
        surface.setLinkPointer(nil)
        return NSCursor.iBeam.set()
      }
    }
    let hit = view.bounds.contains(point) ? surface.hit(point) : nil
    let armed = flags.contains(.command) && hit?.area == .text
    surface.setLinkPointer(armed ? point : nil)
    guard let hit else { return }
    if hit.area != .text {
      NSCursor.arrow.set()
    } else if armed, surface.focused, surface.link(at: point) != nil {
      NSCursor.pointingHand.set()
    } else {
      NSCursor.iBeam.set()
    }
  }
}

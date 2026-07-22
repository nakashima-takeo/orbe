import AppKit

/// chrome キー（Keybindings が先取りした ChromeAction）を surface 操作・ウィンドウ操作へ振り分ける。
extension SurfaceView {
  func perform(_ action: ChromeAction) {
    // window コマンドは単一ソース mapping で一本化（surface 経路・window レベル経路が共有）。
    // availableWithoutTabs のコマンドは surface 在席時も root が先に消費するためここへは来ないが、
    // mapping は網羅ゆえ残す（window 経路優先・surface 経路はフォールバック定義）。
    if let command = action.windowCommand {
      controller?.requestWindowCommand(command)
      return
    }
    // 残りは surface ローカル操作。
    switch action {
    case .increaseFontSize: surfaceBinding("increase_font_size:1")
    case .decreaseFontSize: surfaceBinding("decrease_font_size:1")
    case .resetFontSize: surfaceBinding("reset_font_size")
    case .splitRight: controller?.split(.horizontal)
    case .splitDown: controller?.split(.vertical)
    case .closePane: controller?.close(self)
    case .find: showSearch()
    case .scrollToTop: surfaceBinding("scroll_to_top")
    case .scrollToBottom: surfaceBinding("scroll_to_bottom")
    default: break  // window コマンドは上で処理済み
    }
  }
}

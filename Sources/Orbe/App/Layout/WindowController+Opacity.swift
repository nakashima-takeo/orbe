import AppKit
import GhosttyKit

/// NSWindow の背景透過を settings の「背景の不透明度」に合わせて適用する橋渡し。
/// libghostty へ渡す surface アルファ（gui.conf の `background-opacity`）だけでは背景が合成されず、
/// ホスト NSWindow が `isOpaque = true`（既定）のままだと透けない。ここで窓プロパティを対で設定する。
/// 本家 ghostty の TerminalWindow.syncAppearance を Orbe 独自 WindowController へ移植したもの。
extension WindowController {
  /// 背景不透明度から窓を透過させるべきか（純関数・テスト可能）。percent<100 かつ非フルスクリーンで透過。
  /// フルスクリーンは常に不透明（背後にデスクトップが無く透過が無意味＝本家踏襲）。
  static func shouldBeTranslucent(percent: Int, isFullScreen: Bool) -> Bool {
    percent < 100 && !isFullScreen
  }

  /// 現在の settings（未設定は fallback 90）と窓のフルスクリーン状態から isOpaque/backgroundColor を再適用する。
  /// init・reload 後・フルスクリーン遷移で呼び、状態が変わっても透過設定が追従する。
  func syncWindowOpacity() {
    let settings = activeEffectiveSettings()
    let percent = settings[SettingKeys.backgroundOpacity]
    let isFullScreen = window.styleMask.contains(.fullScreen)
    let translucent = Self.shouldBeTranslucent(percent: percent, isFullScreen: isFullScreen)
    window.isOpaque = !translucent
    // .white.withAlphaComponent(0.001) は本家踏襲（.clear より Terminal.app に近い見た目で、
    // 完全透明でないためヒットテスト等が壊れない）。不透明時は system 動的色へ戻す。
    window.backgroundColor =
      translucent ? .white.withAlphaComponent(0.001) : .windowBackgroundColor
    // chrome 各面（StatusRow・パレット・EditorPane）を端末面と同じ材料で透過させる。
    // 端末面 veil は libghostty が、chrome veil は各面が effectiveOpacity で塗る（二重 veil 回避）。
    chromeTranslucency.update(
      percent: percent, isFullScreen: isFullScreen, blur: settings[SettingKeys.backgroundBlur])
  }

  /// ウィンドウ背後のすりガラス（CGS）ブラーを現在の config に合わせて再適用する。
  /// libghostty(Zig) 側が呼び出し時に config の `background-blur` を半径として読み、gui.conf の
  /// `background-opacity >= 1.0`（不透明）なら早期 return する。半径・opacity ゲートは Zig 側が config を
  /// 読んで判定するため Swift で再実装せず、gui.conf 更新→reloadConfig の後にこれを呼べばよい。
  /// フルスクリーンは syncWindowOpacity と同じく Swift 側で除外する（本家踏襲）——フルスクリーン中は
  /// config の background-opacity が据え置きで Zig は早期 return せず、opaque 窓の背後に blur を敷いても
  /// 不可視で無駄なため。CGS は windowNumber ベースで可視後でないと効かず、初回適用は windowDidBecomeKey が担う。
  func syncWindowBlur() {
    guard !window.styleMask.contains(.fullScreen) else { return }
    ghostty_set_window_background_blur(
      Ghostty.shared.app, Unmanaged.passUnretained(window).toOpaque())
  }

  // フルスクリーン遷移で透過を切り替える（入る＝不透明へ・出る＝設定値へ戻す）。ブラーも対で追従させる。
  func windowDidEnterFullScreen(_ notification: Notification) {
    syncWindowOpacity()
    syncWindowBlur()
  }
  func windowDidExitFullScreen(_ notification: Notification) {
    syncWindowOpacity()
    syncWindowBlur()
  }
}

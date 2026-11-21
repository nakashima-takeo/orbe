import AppKit

@testable import Orbe

/// Orbe のウィンドウ（`OrbeWindow`）のフェイク。key かどうかをテストが決め、前面化は呼び出された回数を記録するだけで、
/// ウィンドウを画面に表示せずアプリも前面化しない。key の得失は AppKit と同じく、状態を変えてから通知を出すので、delegate と、
/// 通知を購読するビューの両方に届く。
/// AppKit の内部（`NSApp.keyWindow`・キーイベントの配送先）は、このフェイクが返す key かどうかの値を見ない。
///
/// シートは画面に出さず、応答待ちとして持つ。`NSAlert.beginSheetModal(for:)` は、ウィンドウのシートの API を通ってここへ届く。
/// `attachedSheet` は応答待ちの先頭のシートを返し、`endSheet(_:returnCode:)` はそのシートの完了ハンドラを応答つきで呼ぶ。
///
/// 並べられている（ordered-in）のにどの画面にも載っていない間（`placeOffscreen` で画面外へ並べた間）は、主ディスプレイに
/// 載っていると答える。AppKit の `NSScrollView` は、画面に載っていない（`screen` が nil の）ウィンドウではホイールで
/// スクロールしない。並べていない間の答えは変えない。
final class OrbeWindowFake: OrbeWindow {
  var isKey = false {
    didSet {
      guard isKey != oldValue else { return }
      NotificationCenter.default.post(
        name: isKey ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
        object: self)
    }
  }
  private(set) var bringToFrontCount = 0
  private var pendingSheets:
    [(sheet: NSWindow, completion: ((NSApplication.ModalResponse) -> Void)?)] = []

  override var isKeyWindow: Bool { isKey }
  override var screen: NSScreen? {
    if ProcessInfo.processInfo.environment["PROBE_NO_SCREEN"] != nil { return super.screen }
    return super.screen ?? (isVisible ? NSScreen.screens.first : nil)
  }
  override func bringToFront() { bringToFrontCount += 1 }

  override func beginSheet(
    _ sheetWindow: NSWindow,
    completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil
  ) {
    pendingSheets.append((sheetWindow, handler))
  }

  override func beginCriticalSheet(
    _ sheetWindow: NSWindow,
    completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil
  ) {
    pendingSheets.append((sheetWindow, handler))
  }

  override var attachedSheet: NSWindow? { pendingSheets.first?.sheet }

  override func endSheet(_ sheetWindow: NSWindow, returnCode: NSApplication.ModalResponse) {
    guard let index = pendingSheets.firstIndex(where: { $0.sheet === sheetWindow }) else { return }
    pendingSheets.remove(at: index).completion?(returnCode)
  }
}

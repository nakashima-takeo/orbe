import AppKit
import GhosttyKit

/// 実行中プロセスの終了確認。ウィンドウ閉じ（`windowShouldClose`）と ⌘Q 終了
/// （`AppDelegate.applicationShouldTerminate`）が共用する。文言は現在言語ホルダーから引く。
extension WindowController {
  // 実行中プロセスがあれば閉じる前に 1 回だけ確認（無警告で殺さない）。
  func windowShouldClose(_ sender: NSWindow) -> Bool { confirmCloseIfNeeded() }

  /// 実行中プロセスがあれば 1 回だけ確認（無ければ true）。
  func confirmCloseIfNeeded() -> Bool {
    guard ghostty_app_needs_confirm_quit(Ghostty.shared.app) else { return true }
    let alert = NSAlert()
    alert.messageText = localization.string(.quitConfirmTitle)
    alert.informativeText = localization.string(.quitConfirmMessage)
    alert.addButton(withTitle: localization.string(.quitConfirmClose))
    alert.addButton(withTitle: localization.string(.quitConfirmCancel))
    return alert.runModal() == .alertFirstButtonReturn
  }
}

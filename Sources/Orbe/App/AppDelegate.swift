import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: WindowController!

  func applicationDidFinishLaunching(_ notification: Notification) {
    windowController = WindowController()
    // 言語変更（初回言語選択の確定・設定パレットの言語行）でメニューを現在言語へ組み直す。
    windowController.onLanguageChanged = { [weak self] in self?.installMainMenu() }
    // 標準 Edit メニューを据える。無いと ⌘V/⌘C/⌘X/⌘A がオーバーレイの入力欄へ届かない（MainMenu 参照）。
    installMainMenu()
    windowController.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    ControlServer.shared.start(target: windowController)  // 外部 → Orbe 制御チャネル
  }

  /// メインメニューを現在の UI 言語で組み直す（起動時・言語変更時の集約点）。theme が `NSApp.appearance` を
  /// 同期するのと同じ位置づけ。言語未確定（初回）は起動時の描画言語（OS 追従）で建てる。
  func installMainMenu() {
    let language = windowController?.localization.language ?? .systemDefault
    NSApp.mainMenu = MainMenu.build(appName: "Orbe", language: language)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  // ⌘Q（メニュー）による終了も、ウィンドウ閉じと同じく実行中プロセスを無警告で殺さない（1 回だけ確認）。
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    (windowController?.confirmCloseIfNeeded() ?? true) ? .terminateNow : .terminateCancel
  }

  // 終了時にデバウンス待ちの構成変更を取りこぼさず確定保存する。
  func applicationWillTerminate(_ notification: Notification) {
    ControlServer.shared.stop()
    windowController?.flushSave()
  }
}

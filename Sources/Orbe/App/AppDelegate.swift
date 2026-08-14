import AppKit
import GhosttyKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: WindowController!
  private var menuBarController: MenuBarController?
  // ⌘⌘ 検知の 2 面。local は前面時（権限不要・常時）、global は背面時（権限あるときだけ install）。
  private var localCmdTap: CmdDoubleTapMonitor?
  private var globalCmdTap: CmdDoubleTapMonitor?

  func applicationDidFinishLaunching(_ notification: Notification) {
    windowController = WindowController()
    // 言語変更（初回言語選択の確定・設定パレットの言語行）でメニューを現在言語へ組み直す。
    windowController.onLanguageChanged = { [weak self] in self?.installMainMenu() }
    // 標準 Edit メニューを据える。無いと ⌘V/⌘C/⌘X/⌘A がオーバーレイの入力欄へ届かない（MainMenu 参照）。
    installMainMenu()
    windowController.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    ControlServer.shared.start(target: windowController)  // 外部 → Orbe 制御チャネル
    // メニューバー投影（Attention の件数・状態変化の一過性表示・ドロップダウン）。
    menuBarController = MenuBarController(
      store: windowController.attentionStore, windowController: windowController,
      localization: windowController.localization)
    // 前面時の ⌘⌘ → Attention パレットのトグル（local monitor は自アプリのイベントのみ・権限不要）。
    localCmdTap = CmdDoubleTapMonitor(scope: .local) { [weak self] in
      guard let self else { return }
      // ドロップダウンは `.nonactivatingPanel` が key を取るので、開いている間の ⌘⌘ は
      // 「他アプリのイベント」ではなくなり global ではなく **local** へ届く。ここで宛先を
      // 分けないと、背面のメイン窓で Attention パレットが無言で開く（開いた覚えのない
      // パレットが次の前面化で出る）。開けたものと同じジェスチャで閉じ切る。
      if let menuBar = self.menuBarController, menuBar.isDropdownOpen {
        menuBar.closeDropdown()
        return
      }
      self.windowController.toggleAttentionPalette()
    }
    syncGlobalCmdTapMonitor()
  }

  /// 権限（Accessibility / Input Monitoring）の付与・剥奪を activation 契機で再評価し、
  /// 背面 ⌘⌘ の global monitor を install/remove する（再起動不要。ただし TCC は付与後も
  /// プロセス再起動まで効かないことがある——誘導文言に再起動の注記がある）。
  func applicationDidBecomeActive(_ notification: Notification) {
    syncGlobalCmdTapMonitor()
  }

  private func syncGlobalCmdTapMonitor() {
    let granted = CmdDoubleTapMonitor.globalMonitoringPermitted
    if granted, globalCmdTap == nil {
      // 背面時の ⌘⌘ → メニューバードロップダウン（global monitor は他アプリのイベントのみ）。
      globalCmdTap = CmdDoubleTapMonitor(scope: .global) { [weak self] in
        self?.menuBarController?.showDropdown()
      }
    } else if !granted {
      globalCmdTap = nil  // 剥奪を検知したら判定ごと止める（flagsChanged だけの誤爆判定はしない）
    }
  }

  /// メインメニューを現在の UI 言語で組み直す（起動時・言語変更時の集約点）。theme が `NSApp.appearance` を
  /// 同期するのと同じ位置づけ。言語未確定（初回）は起動時の描画言語（OS 追従）で建てる。
  func installMainMenu() {
    let language = windowController?.localization.language ?? .systemDefault
    // 表示名は Info.plist（＝ビルド時のチャネルが導出した値）から取る。ここを固定にすると
    // Orbe Dev のメニューだけ「Orbeを終了」と名乗り、共存時の見分けが最も目に付く場所で崩れる。
    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Orbe"
    NSApp.mainMenu = MainMenu.build(appName: appName, language: language)
  }

  /// App メニュー「更新を確認…」（target=nil の responder chain 配送でここへ届く）。
  /// 設定パレットの「今すぐ確認」と同一導線——結果は設定›アップデートの状態カードに現れる。
  @objc func checkForUpdates(_ sender: Any?) {
    windowController?.showUpdateCheck()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    confirmQuitIfNeeded() ? .terminateNow : .terminateCancel
  }

  /// 実行中プロセスがあれば終了前に 1 回だけ確認する（無警告で殺さない）。窓の ✕・⌘Q／メニュー・
  /// アップデートの再起動・ログアウトまで、あらゆる終了がこの 1 箇所を通る。文言は現在言語で引く
  /// （言語ホルダーが立つ前に終了要求が届いたときは OS 追従。文言を引けないことは確認を省く理由にならない）。
  private func confirmQuitIfNeeded() -> Bool {
    guard ghostty_app_needs_confirm_quit(Ghostty.shared.app) else { return true }
    let language = windowController?.localization.language ?? .systemDefault
    let alert = NSAlert()
    alert.messageText = L10n.string(.quitConfirmTitle, language)
    alert.informativeText = L10n.string(.quitConfirmMessage, language)
    alert.addButton(withTitle: L10n.string(.quitConfirmQuit, language))
    alert.addButton(withTitle: L10n.string(.quitConfirmCancel, language))
    return alert.runModal() == .alertFirstButtonReturn
  }

  // 終了時にデバウンス待ちの構成変更を取りこぼさず確定保存する。
  func applicationWillTerminate(_ notification: Notification) {
    ControlServer.shared.stop()
    windowController?.flushSave()
  }
}

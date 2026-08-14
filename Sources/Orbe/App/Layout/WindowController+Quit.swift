import AppKit

/// 窓の ✕ をアプリ終了の要求へ橋渡しする。終了してよいかの判断（実行中プロセスの確認）は
/// 唯一の関門である `AppDelegate.applicationShouldTerminate` が持つ。
extension WindowController {
  /// Orbe は単一ウィンドウなので、この窓を閉じることはアプリを終了することと同義。本当の問いは
  /// 「閉じてよいか」ではなく「終了してよいか」なので、可否は終了の関門へ委ね、ここでは窓を閉じずに
  /// 終了を要求するだけにする。先に窓を閉じてしまうと、確認をキャンセルしたときに
  /// メニューバーの常駐アイテムだけが残るゾンビ状態になる。窓が閉じるのは終了が確定した後。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // 「閉じてよいか」を即答する契約に従い、確認モーダルと終了シーケンスは次のランループへ送る。
    DispatchQueue.main.async { NSApp.terminate(nil) }
    return false
  }
}

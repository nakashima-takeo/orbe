import AppKit
import OrbeEditorCore

/// 窓の ✕ をアプリ終了の要求へ橋渡しする。終了してよいかの判断（実行中プロセスの確認）は
/// 唯一の関門である `AppDelegate.applicationShouldTerminate` が持つ。
extension WindowController {
  /// Orbe は単一ウィンドウなので、この窓を閉じることはアプリを終了することと同義。本当の問いは
  /// 「閉じてよいか」ではなく「終了してよいか」なので、可否は終了の関門へ委ね、ここでは窓を閉じずに
  /// 終了を要求するだけにする。先に窓を閉じてしまうと、確認をキャンセルしたときに
  /// メニューバーの常駐アイテムだけが残るゾンビ状態になる。窓が閉じるのは終了が確定した後。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // 「閉じてよいか」を即答する契約に従い、確認モーダルと終了シーケンスは次のランループへ送る。
    // main キューではなくランループへ積む。キューのブロック実行中にモーダルへ入ると、その入れ子の
    // 間 main キューは次を捌けず、端末描画（`Ghostty` の wakeup → tick）も制御 API も答えを待つ間
    // 止まってしまう——実行中プロセスの是非を問う画面で、当のプロセスの出力が凍る。
    RunLoop.main.perform { NSApp.terminate(nil) }
    return false
  }

  /// 全 workspace の全タブで、閉じれば失われる文書（未保存の列）。終了の関門が読む。
  func unsavedDocuments() -> [EditorDocument] {
    workspaces.flatMap { $0.tabs.flatMap { $0.unsavedDocuments() } }
  }

  /// 未保存の確認を sheet で出し、保存／保存しないで進んでよければ `proceed` を呼ぶ（保存が外部変更で
  /// 失敗すれば呼ばない）。タブを閉じる・workspace を閉じるの 2 入口が共有する。sheet は非同期に
  /// 確定する——`tab.close` は main-queue のブロックから届き、その中のモーダルは端末描画と制御 API を
  /// 止める（`windowShouldClose` の注記）。
  func confirmDiscard(_ unsaved: [EditorDocument], then proceed: @escaping () -> Void) {
    MainActor.assumeIsolated {
      UnsavedGate.alert(count: unsaved.count, language: localization.language).beginSheetModal(
        for: window
      ) { response in
        if UnsavedGate.proceed(response, discarding: unsaved) { proceed() }
      }
    }
  }
}

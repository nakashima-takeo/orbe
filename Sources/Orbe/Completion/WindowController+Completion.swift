import AppKit

/// 補完（zsh ドロップダウン）まわりの WindowController 拡張。
/// 補完関心を WindowController 本体から分離する（init から呼ぶスタートアップフック）。
extension WindowController {
  /// 補完 managed block を zshrc へ初回だけ追記する。バンドル有時（同梱スクリプト有）のみ・
  /// バックグラウンドで冪等実行し、フラグでゲートする（`agentPluginsInstalled` に倣う）。
  func installCompletionIfNeeded() {
    guard AppStatePersistence.load()?.completionInstalled != true,
      SurfaceView.completionScriptPath != nil
    else { return }
    DispatchQueue.global(qos: .utility).async {
      CompletionInstaller.install()
      DispatchQueue.main.async {
        AppStatePersistence.update { $0.completionInstalled = true }
      }
    }
  }
}

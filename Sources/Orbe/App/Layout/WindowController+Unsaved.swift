import AppKit
import OrbeEditorCore

/// 未保存の関門——閉じれば失われる文書を集め、捨てる前の確認を出す。タブを閉じる・workspace を閉じるの
/// 2 入口が sheet で共有し、終了の関門（`AppDelegate`）は集める側だけを使ってモーダルで確認する。
/// 解決の規則は `UnsavedGate`。
extension WindowController {
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

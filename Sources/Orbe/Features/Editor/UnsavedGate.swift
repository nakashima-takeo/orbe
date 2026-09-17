import AppKit
import OrbeEditorCore

/// 未保存を捨てる前の確認（保存／保存しない／キャンセル）と、外部変更で失敗した保存の上書き確認。
/// 「提示」と「解決」を分け、保存の実行と可否の規則は `proceed` にしか無い——提示点（ファイルタブの ×・
/// 人の操作でタブを閉じる・workspace の削除・終了）は sheet か runModal かを選ぶだけ。
@MainActor
enum UnsavedGate {
  /// 捨てる文書の件数を添えた確認。ボタンは 保存（既定）／保存しない／キャンセル（Esc）。
  static func alert(count: Int, language: Language) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = L10n.string(.editorUnsavedTitle, language)
    alert.informativeText = L10n.format(
      count == 1 ? .editorUnsavedMessageOne : .editorUnsavedMessageOther, language, count)
    alert.addButton(withTitle: L10n.string(.editorUnsavedSave, language))
    alert.addButton(withTitle: L10n.string(.editorUnsavedDiscard, language)).hasDestructiveAction =
      true
    alert.addButton(withTitle: L10n.string(.commonCancel, language)).keyEquivalent = "\u{1b}"
    return alert
  }

  /// 応答を解決する。保存 → 順に `save()`（1 つでもディスクの変更で失敗すれば false。失敗した文書は印が
  /// 立ったまま残り、⌘S の上書き確認へ）／保存しない → true／キャンセル → false。
  static func proceed(
    _ response: NSApplication.ModalResponse, discarding documents: [EditorDocument]
  )
    -> Bool
  {
    switch response {
    case .alertFirstButtonReturn:
      for document in documents {
        do {
          try document.save()
        } catch {
          return false
        }
      }
      return true
    case .alertSecondButtonReturn:
      return true
    default:
      return false
    }
  }

  /// 印の立った文書の ⌘S。ボタンは 上書き／キャンセル（Esc）。
  static func overwriteAlert(language: Language) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = L10n.string(.editorOverwriteTitle, language)
    alert.informativeText = L10n.string(.editorOverwriteMessage, language)
    alert.addButton(withTitle: L10n.string(.editorOverwriteConfirm, language))
      .hasDestructiveAction =
      true
    alert.addButton(withTitle: L10n.string(.commonCancel, language)).keyEquivalent = "\u{1b}"
    return alert
  }

  static func shouldOverwrite(_ response: NSApplication.ModalResponse) -> Bool {
    response == .alertFirstButtonReturn
  }
}

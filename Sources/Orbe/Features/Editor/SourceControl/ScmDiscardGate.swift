import AppKit

/// 破棄の確認。追跡中のファイルを含む破棄は作業ツリーを index の版へ戻すので元に戻せず、確認を出す。未追跡だけならゴミ箱へ
/// 移す（戻せる）ので確認しない。「破棄」はクリックだけで確定し、Return では確定しない（`UnsavedGate.overwriteAlert` と同じ
/// 型。Esc はキャンセル）。
@MainActor
enum ScmDiscardGate {
  static func needsConfirmation(_ files: [ScmChanges.File]) -> Bool {
    files.contains(where: \.isTracked)
  }

  /// 件数（1 件ならその名前）と、未追跡を含めばゴミ箱へ移す件数を添えた確認。
  static func alert(_ files: [ScmChanges.File], language: Language) -> NSAlert {
    let alert = NSAlert()
    alert.messageText =
      files.count == 1
      ? L10n.format(
        .editorScmDiscardTitleOne, language, (files[0].path as NSString).lastPathComponent)
      : L10n.format(.editorScmDiscardTitleOther, language, files.count)
    let untracked = files.filter { !$0.isTracked }.count
    alert.informativeText = [
      L10n.string(.editorScmDiscardMessage, language),
      untracked > 0 ? L10n.format(.editorScmDiscardUntracked, language, untracked) : nil,
    ].compactMap { $0 }.joined(separator: " ")
    let confirm = alert.addButton(withTitle: L10n.string(.editorScmDiscardConfirm, language))
    confirm.hasDestructiveAction = true
    confirm.keyEquivalent = ""
    alert.addButton(withTitle: L10n.string(.commonCancel, language)).keyEquivalent = "\u{1b}"
    return alert
  }

  static func shouldDiscard(_ response: NSApplication.ModalResponse) -> Bool {
    response == .alertFirstButtonReturn
  }
}

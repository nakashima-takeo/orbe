import AppKit

/// 破棄の確認。index の版へ戻すパスを含む破棄は元に戻せないので、確認を出す。ゴミ箱へ移すもの（未追跡・作業ツリーに在る
/// intent-to-add）だけなら戻せるので確認しない。行き先は行に写した規則（`ScmChanges.File.discardMovesToTrash`）で決める。
/// 「破棄」はクリックだけで確定し、Return では確定しない（`UnsavedGate.overwriteAlert` と同じ型。Esc はキャンセル）。
@MainActor
enum ScmDiscardGate {
  /// 戻すパスを 1 つでも含む——ゴミ箱へ移らない行か、元パス（rename の元パスは戻す側）を持つ行がある。
  static func needsConfirmation(_ files: [ScmChanges.File]) -> Bool {
    files.contains { !$0.discardMovesToTrash || $0.row.originalPath != nil }
  }

  /// 根のサービスへ渡す、見えていた破棄。
  static func content(_ files: [ScmChanges.File]) -> GitDiscardContent {
    GitDiscardContent(
      rows: files.map(\.row), trashed: Set(files.filter(\.discardMovesToTrash).map(\.path)))
  }

  /// 件数（1 件ならその名前）と、ゴミ箱へ移す行があればその件数を添えた確認。
  static func alert(_ files: [ScmChanges.File], language: Language) -> NSAlert {
    let alert = NSAlert()
    alert.messageText =
      files.count == 1
      ? L10n.format(
        .editorScmDiscardTitleOne, language, (files[0].path as NSString).lastPathComponent)
      : L10n.format(.editorScmDiscardTitleOther, language, files.count)
    let trashed = files.filter(\.discardMovesToTrash).count
    alert.informativeText = [
      L10n.string(.editorScmDiscardMessage, language),
      trashed > 0
        ? L10n.format(
          trashed == 1 ? .editorScmDiscardToTrashOne : .editorScmDiscardToTrashOther, language,
          trashed) : nil,
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

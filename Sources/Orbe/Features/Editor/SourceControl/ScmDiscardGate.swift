import Foundation

/// 破棄の確認。index の版へ戻すパスを含む破棄は元に戻せないので、面の中の確認（→ `EditorConfirm`）を出す。ゴミ箱へ移すもの
/// （未追跡・作業ツリーに在る intent-to-add）だけなら戻せるので確認しない。行き先は行に写した規則
/// （`ScmChanges.File.discardMovesToTrash`）で決める。「破棄」はクリックだけで確定し、↵ では確定しない。esc はキャンセル。
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

  /// 面の中の確認の中身——題は件数（1 件ならその名前）、本文はゴミ箱へ移す行があればその件数を添える。
  static func confirmation(_ files: [ScmChanges.File], language: Language) -> EditorConfirmContent {
    let title =
      files.count == 1
      ? L10n.format(
        .editorScmDiscardTitleOne, language, (files[0].path as NSString).lastPathComponent)
      : L10n.format(.editorScmDiscardTitleOther, language, files.count)
    let trashed = files.filter(\.discardMovesToTrash).count
    let restore = L10n.string(.editorScmDiscardMessage, language)
    let message =
      trashed > 0
      ? L10n.format(
        .editorScmDiscardMessageWithTrash, language, restore,
        L10n.format(
          trashed == 1 ? .editorScmDiscardToTrashOne : .editorScmDiscardToTrashOther, language,
          trashed))
      : restore
    return EditorConfirmContent(
      title: title, message: message,
      confirmTitle: L10n.string(.editorScmDiscardConfirm, language),
      label: L10n.string(.editorScmDiscard, language))
  }
}

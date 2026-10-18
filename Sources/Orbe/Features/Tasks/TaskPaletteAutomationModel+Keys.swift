import SwiftUI

/// 提案タブのキー。絞り込み欄と候補の一覧は入力欄に焦点があり、↵ は入力欄の `onSubmit`、esc（どの居場所でも閉じる）と
/// ⇥・⇧⇥ は画面のモデルが受ける。棚はカードの器に焦点がある。取り消せない操作（捨てる）・タスクにして開く・ブラウザで開く・候補の
/// 更新は押した瞬間だけを操作にし、押し続けたキーリピートは捨てる。
extension TaskPaletteAutomationModel {
  /// 入力欄（絞り込み欄と候補の一覧）。捨てるは ⌘⌫ で、入力欄が空のときだけ効く（文字があれば行頭まで消す）——焦点が
  /// 絞り込み欄にあるので、単キーにすると絞り込みのつもりで打った 1 文字で候補が消える。候補をさばくキーは選ばれている
  /// 候補にだけ効くので、絞り込み欄では何もしない。
  func handleFieldKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      let direction = press.key == .upArrow ? -1 : 1
      guard place == .proposals else {
        if direction > 0, TaskPaletteModel.isUnmodified(press) { enterShelf() }
        return .handled
      }
      if press.modifiers.contains(.command) {
        jumpProposal(direction)
      } else {
        moveProposal(direction)
      }
    case .return where press.modifiers.contains(.command):
      if press.phase == .down { acceptAndOpen() }
    case _ where TaskPaletteModel.isOpenInBrowserKey(press):
      if press.phase == .down { openLink() }
    case _ where TaskPaletteModel.isCommandBackspace(press):
      guard query.isEmpty else { return .ignored }
      if press.phase == .down { dismiss() }
    case .leftArrow:
      guard TaskPaletteModel.isUnmodified(press), query.isEmpty else { return .ignored }
      enterShelf()
    default:
      return .ignored
    }
    return .handled
  }

  /// 棚。
  func handleShelfKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.command) { jumpShelf(direction) } else { moveShelf(direction) }
    case .return where press.modifiers.contains(.command):
      if press.phase == .down { refresh() }
    case .rightArrow, .return: enterProposals()
    default: return .ignored
    }
    return .handled
  }
}

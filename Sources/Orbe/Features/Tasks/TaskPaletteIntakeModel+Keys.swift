import SwiftUI

/// 受信タブのキー。↵（提案の一覧）は入力欄の `onSubmit`、esc（提案の一覧）と ⇧⇥ は画面のモデルが受ける。中身のキーは
/// `IntakeHand` の写し（ボードと同じ）。取り消せない操作（捨てる・削除）とブラウザで開くは押した瞬間だけを操作にし、押し続けた
/// キーリピートは捨てる。
extension TaskPaletteIntakeModel {
  /// 入力欄（提案の一覧）。捨てるは ⌘⌫ で、入力欄が空のときだけ効く（文字があれば行頭まで消す）——焦点が絞り込み欄に
  /// あるので、単キーにすると絞り込みのつもりで打った 1 文字で提案が消える。
  func handleFieldKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.command) {
        jumpProposal(direction)
      } else if !press.modifiers.contains(.option) {
        moveProposal(direction)
      }
    case .return where press.modifiers.contains(.command):
      if press.phase == .down { openLink() }
    case _ where TaskPaletteModel.isCommandBackspace(press):
      guard query.isEmpty else { return .ignored }
      if press.phase == .down { dismiss() }
    case .rightArrow:
      guard TaskPaletteModel.isUnmodified(press), selectedIntake != nil else { return .ignored }
      enterContents()
    case .leftArrow:
      guard TaskPaletteModel.isUnmodified(press), query.isEmpty else { return .ignored }
      enterShelf()
    case .tab:
      break
    default:
      return .ignored
    }
    return .handled
  }

  /// カードの器（棚と中身）。⇥・⇧⇥ は握るだけ（焦点を逃がさず、タブも替えない）。
  func handleCardKey(_ press: KeyPress) -> KeyPress.Result {
    switch place {
    case .proposals: return .ignored
    case .shelf: return handleShelfKey(press)
    case .contents: return handleContentsKey(press)
    }
  }

  private func handleShelfKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.command) { jumpShelf(direction) } else { moveShelf(direction) }
    case .rightArrow, .return, .escape: showProposals()
    case .tab, .backtab: break
    default: return .ignored
    }
    return .handled
  }

  private func handleContentsKey(_ press: KeyPress) -> KeyPress.Result {
    if let stroke = IntakeHand.stroke(press) {
      if case .press(let operation) = stroke { perform(operation) }
      return .handled
    }
    switch press.key {
    case .leftArrow, .escape: showProposals()
    case .return, .tab, .backtab: break
    default: return .ignored
    }
    return .handled
  }
}

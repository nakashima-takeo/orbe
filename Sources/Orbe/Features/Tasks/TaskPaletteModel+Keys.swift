import SwiftUI

/// 焦点ごとのキーの意味。⇥・⇧⇥ はどの焦点でも握る（握らないと焦点がカードの外へ逃げ、以後のキーが
/// 届かない）。矢印は単一の catch-all で修飾の有無を分ける。日本語入力の変換中（`composing`）は
/// 入力欄のキーを一切握らず、変換に使わせる。
extension TaskPaletteModel {
  /// ヘッダーの入力欄（一覧）。↵ は `onSubmit` が受ける（変換確定の ↵ では発火しない）。
  func handleFieldKey(_ press: KeyPress, composing: Bool) -> KeyPress.Result {
    guard !composing else { return .ignored }
    if Self.isBacktab(press) {
      toggleTab()
      return .handled
    }
    switch press.key {
    case .upArrow, .downArrow:
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.option) {
        reorder(direction)
      } else if press.modifiers.contains(.command) {
        jump(direction)
      } else {
        move(direction)
      }
    case .tab:
      toggleScope()
    case .rightArrow:
      guard Self.isUnmodified(press), selectedTask != nil else { return .ignored }
      enterDetail()
    case .space:
      // 文字があるときの space は空白を打つ。
      guard query.isEmpty, Self.isUnmodified(press), tab == .tasks else { return .ignored }
      // 押し続けたキーリピートは握り潰す（次の行を次々に完了にしない。入力欄へ空白も入れない）。
      guard press.phase == .down else { return .handled }
      switch selectedID {
      case .task(let id): toggleDone(id)
      case .doneHeader: toggleDoneExpanded()
      case .add, nil: break
      }
    case _ where Self.isCommandBackspace(press):
      // 文字があるときの ⌘⌫ は行頭まで消す。消して空になった瞬間のキーリピートは削除に使わない。
      guard query.isEmpty else { return .ignored }
      if press.phase == .down, tab == .tasks, case .task(let id) = selectedID { delete(id) }
    case .escape:
      onDismiss()
    default:
      return .ignored
    }
    return .handled
  }

  /// カードの器（詳細の項目に居て、編集していない間）。
  func handleCardKey(_ press: KeyPress) -> KeyPress.Result {
    guard draft == nil, case .detail(let field) = area else { return .ignored }
    if Self.isBacktab(press) { return .handled }
    switch press.key {
    case .upArrow: moveField(-1)
    case .downArrow: moveField(1)
    case .leftArrow: if !changeValue(-1) { leaveDetail() }
    case .rightArrow: changeValue(1)
    case .return: if field.isText { beginEditing() }
    case .space:
      if press.phase == .down, let task = selectedTask { toggleDone(task.id) }
    case _ where Self.isCommandBackspace(press):
      if press.phase == .down, let task = selectedTask { delete(task.id) }
    case .escape: leaveDetail()
    case .tab: break
    default: return .ignored
    }
    return .handled
  }

  /// 詳細の編集欄。1 行の項目の ↵ は `onSubmit` が受け、メモは ↵ を改行に使って ⌘↵ で確定する。
  func handleEditKey(_ press: KeyPress, composing: Bool) -> KeyPress.Result {
    guard !composing, draft != nil else { return .ignored }
    if Self.isBacktab(press) { return .handled }
    switch press.key {
    case .escape: endEditing(commit: false)
    case .return where press.modifiers.contains(.command): endEditing(commit: true)
    case .tab: break
    default: return .ignored
    }
    return .handled
  }

  /// 押している修飾キーが無いか。実機の矢印キーは numericPad と function の修飾を伴って届くので、
  /// 修飾の集合が空かでは判定しない。
  private static func isUnmodified(_ press: KeyPress) -> Bool {
    press.modifiers.isDisjoint(with: [.command, .option, .control, .shift])
  }

  /// ⌘⌫。⌫ は AppKit から DEL（U+007F）で届き、`KeyEquivalent.delete`（U+0008）とは一致しない。
  private static func isCommandBackspace(_ press: KeyPress) -> Bool {
    press.modifiers.contains(.command)
      && (press.key.character == "\u{7F}" || press.key == .delete)
  }

  /// ⇧⇥ は `.tab` ではなく AppKit の backtab 文字（U+0019）で届く。
  private static func isBacktab(_ press: KeyPress) -> Bool {
    press.key.character == "\u{19}"
  }
}

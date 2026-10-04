import SwiftUI

/// 焦点ごとのキーの意味。⇥・⇧⇥ はどの焦点でも握る（握らないと焦点がカードの外へ逃げ、以後のキーが
/// 届かない）。矢印は単一の catch-all で修飾の有無を分ける。日本語入力の変換中（`composing`）は
/// 入力欄のキーを一切握らず、変換に使わせる。
extension TaskPaletteModel {
  /// ヘッダーの入力欄（一覧）。↵ は `onSubmit` が受ける（変換確定の ↵ では発火しない）。`onSubmit` は
  /// キーリピートでも発火するので、↵ のリピートはここで握り潰す（押し続けて次々に完了にする・タスクにしない）。
  func handleFieldKey(_ press: KeyPress, composing: Bool) -> KeyPress.Result {
    guard !composing else { return .ignored }
    if press.key == .return, press.phase == .repeat { return .handled }
    if Self.isBacktab(press) {
      toggleTab()
      return .handled
    }
    return visibleTab == .tasks ? handleTaskFieldKey(press) : handleGitHubFieldKey(press)
  }

  private func handleTaskFieldKey(_ press: KeyPress) -> KeyPress.Result {
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
      guard query.isEmpty, Self.isUnmodified(press) else { return .ignored }
      // 結び付けるタスクを選ぶ間は完了にしない。空の入力欄へ空白も入れない。
      guard pick == nil else { return .handled }
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
      if press.phase == .down, case .task(let id) = selectedID { delete(id) }
    case .escape:
      if pick == nil { onDismiss() } else { cancelPick() }
    default:
      return .ignored
    }
    return .handled
  }

  /// GitHub タブの入力欄（一覧）。結び付ける（⌘L）と外す（⌘⌫）は修飾付きのキーにして、絞り込みの文字を
  /// 打つ・消すのと衝突させない。どちらも押した瞬間だけを操作にする（押し続けたキーリピートで、選択が
  /// 移った先の行まで操作しない）。
  private func handleGitHubFieldKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.command) {
        jump(direction)
      } else if !press.modifiers.contains(.option) {
        move(direction)
      }
    case .tab:
      cycleGitHubFilter()
    case .rightArrow:
      guard Self.isUnmodified(press), pick == nil, let row = selectedGitHubRow, row.task == nil
      else { return .ignored }
      enterPane()
    case _ where Self.isLinkKey(press):
      if press.phase == .down, pick == nil { linkSelectedGitHubItem() }
    case _ where Self.isCommandBackspace(press):
      if press.phase == .down, pick == nil, selectedGitHubRow?.task != nil {
        unlinkSelectedGitHubItem()
      }
    case .escape:
      if pick == nil { onDismiss() } else { cancelPick() }
    default:
      return .ignored
    }
    return .handled
  }

  /// カードの器（詳細か右の欄の項目に居て、編集していない間）。
  func handleCardKey(_ press: KeyPress) -> KeyPress.Result {
    guard draft == nil else { return .ignored }
    switch area {
    case .list: return .ignored
    case .pane(let stop): return handlePaneKey(press, stop)
    case .detail(let stop): return handleDetailKey(press, stop)
    }
  }

  private func handleDetailKey(_ press: KeyPress, _ stop: TaskDetailStop) -> KeyPress.Result {
    if Self.isBacktab(press) { return .handled }
    switch press.key {
    case .upArrow: moveField(-1)
    case .downArrow: moveField(1)
    case .leftArrow: if !changeValue(-1) { leaveDetail() }
    case .rightArrow: changeValue(1)
    case .return:
      switch stop {
      case .field(let field): if field.isText { beginEditing() }
      case .agent: if press.phase == .down { focusAgentTab() }
      // 押し続けたキーリピートで、同じページを何度も開かない。
      case .link(let item): if press.phase == .down { openLink(item) }
      case .addLink: if press.phase == .down { beginPickingItem() }
      }
    case .space:
      if press.phase == .down, let task = selectedTask { toggleDone(task.id) }
    case _ where Self.isCommandBackspace(press):
      if press.phase == .down, let task = selectedTask { delete(task.id) }
    case _ where Self.isBackspace(press):
      // 押し続けたキーリピートで、焦点が移った先の結び付きまで外さない。
      guard case .link(let item) = stop else { return .ignored }
      if press.phase == .down { unlink(item) }
    case .escape: leaveDetail()
    case .tab: break
    default: return .ignored
    }
    return .handled
  }

  /// 右の欄の項目。↵（期限の項目以外）と ⌘L は、行の「タスクにする」「結び付ける」と同じ。
  private func handlePaneKey(_ press: KeyPress, _ stop: TaskGitHubPaneStop) -> KeyPress.Result {
    if Self.isBacktab(press) { return .handled }
    switch press.key {
    case .upArrow: movePaneStop(-1)
    case .downArrow: movePaneStop(1)
    case .leftArrow: if !changePaneValue(-1) { leavePane() }
    case .rightArrow: changePaneValue(1)
    case .space:
      if press.phase == .down, stop == .assign { togglePaneAssign() }
    case .return:
      guard press.phase == .down else { break }
      if stop == .due {
        beginPaneDue()
      } else if let row = selectedGitHubRow {
        makeTask(row)
      }
    case _ where Self.isLinkKey(press):
      if press.phase == .down { linkSelectedGitHubItem() }
    case .escape: leavePane()
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
    press.modifiers.contains(.command) && press.key.character == "\u{7F}"
  }

  /// 結び付ける（⌘L）。
  private static func isLinkKey(_ press: KeyPress) -> Bool {
    press.modifiers.contains(.command) && press.modifiers.isDisjoint(with: [.option, .control])
      && press.key.character.lowercased() == "l"
  }

  /// 修飾なしの ⌫。
  private static func isBackspace(_ press: KeyPress) -> Bool {
    isUnmodified(press) && press.key.character == "\u{7F}"
  }

  /// ⇧⇥ は `.tab` ではなく AppKit の backtab 文字（U+0019）で届く。
  private static func isBacktab(_ press: KeyPress) -> Bool {
    press.key.character == "\u{19}"
  }
}

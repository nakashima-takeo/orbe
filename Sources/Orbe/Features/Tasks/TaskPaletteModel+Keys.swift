import SwiftUI

/// カードのキー。カードの入口が全キーを受け、カード全体のキー（⇥・⇧⇥）を先に、残りを焦点の行き先の場所の
/// キーへ振り分ける。どの場所も握らないキーは文字入力・`onSubmit` へ落ちる。矢印は単一の catch-all で修飾の有無を分ける。
extension TaskPaletteModel {
  /// タブを巡れるか（編集中でも選ぶ状態でもない）。⇥・⇧⇥ とフッターの「⇥ タブ」が見る。
  var cyclesTabs: Bool { draft == nil && pick == nil }

  /// カードの唯一のキーの入口。⇥・⇧⇥ は巡れなくても握る（握らないと焦点がカードの外へ逃げ、以後のキーが届かない）。
  func handleKey(_ press: KeyPress) -> KeyPress.Result {
    if press.key == .tab || press.key == .backtab {
      if cyclesTabs { setTab(press.key == .tab ? tab.next : tab.previous) }
      return .handled
    }
    switch focusTarget {
    case .field: return handleFieldKey(press)
    case .card: return handlePlaceKey(press)
    case .edit, .paneDue: return handleEditKey(press)
    }
  }

  /// ヘッダーの入力欄（一覧）。↵ は `onSubmit` が受ける（変換確定の ↵ では発火しない。押し続けたキーリピート
  /// は確定の入口が捨てる——押し続けて次々に完了にする・タスクにしない）。
  private func handleFieldKey(_ press: KeyPress) -> KeyPress.Result {
    switch visibleTab {
    case .tasks: return handleTaskFieldKey(press)
    case .github: return handleGitHubFieldKey(press)
    case .automation:
      guard press.key == .escape else { return automation.handleFieldKey(press) }
      onDismiss()
      return .handled
    }
  }

  private func handleTaskFieldKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.command) {
        jump(direction)
      } else {
        move(direction)
      }
    case .return where press.modifiers.contains(.command):
      // onSubmit（↵ = 選んだ行の操作）へ流さず握る。押し続けたリピートでは動かない。
      guard press.phase == .down, pick == nil else { break }
      switch selectedID {
      case .add: askWithQuery()
      case .task(let id): openAgent(forTask: id)
      case nil: break
      }
    case .rightArrow:
      guard Self.isUnmodified(press), pick == nil, selectedTask != nil else { return .ignored }
      enterDetail()
    case .space:
      // 文字があるときの space は空白を打つ。
      guard query.isEmpty, Self.isUnmodified(press) else { return .ignored }
      // 結び付けるタスクを選ぶ間は完了にしない。空の入力欄へ空白も入れない。
      guard pick == nil else { return .handled }
      // 押し続けたキーリピートは握り潰す（次の行を次々に完了にしない。入力欄へ空白も入れない）。
      guard press.phase == .down else { return .handled }
      if case .task(let id) = selectedID { toggleDone(id) }
    case _ where Self.isCommandBackspace(press):
      // 文字があるときの ⌘⌫ は行頭まで消す。消して空になった瞬間のキーリピートは削除に使わない。
      guard query.isEmpty else { return .ignored }
      if press.phase == .down, case .task(let id) = selectedID { delete(id) }
    case .escape:
      escapeTaskList()
    default:
      return .ignored
    }
    return .handled
  }

  /// タスクのタブの一覧の esc。絞り込みのメニューが開いていればまずそれだけを閉じ、選ぶ状態ならやめ、どちらでもなければ
  /// 画面を閉じる。
  private func escapeTaskList() {
    if openFilterMenu != nil {
      closeFilterMenu()
    } else if pick == nil {
      onDismiss()
    } else {
      cancelPick()
    }
  }

  /// GitHub タブの入力欄（一覧）。結び付ける（⌘L）・外す（⌘⌫）・タスクにして開く（⌘↵）・ブラウザで開く（⌘O）は
  /// 修飾付きのキーにして、絞り込みの文字を打つ・消すのと衝突させない。どれも押した瞬間だけを操作にする（押し続けた
  /// キーリピートで、選択が移った先の行まで操作しない）。⌘↵ は選ぶ状態でも握る（`onSubmit` へ流すと ↵ の
  /// 結び付けとして働く）。
  private func handleGitHubFieldKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow, .downArrow:
      let direction = press.key == .upArrow ? -1 : 1
      if press.modifiers.contains(.command) {
        jump(direction)
      } else {
        move(direction)
      }
    case .rightArrow:
      guard Self.isUnmodified(press), pick == nil, let row = selectedGitHubRow, row.task == nil
      else { return .ignored }
      enterPane()
    case _ where Self.isLinkKey(press):
      if press.phase == .down, pick == nil { linkSelectedGitHubItem() }
    case _ where Self.isOpenInBrowserKey(press):
      if press.phase == .down, pick == nil { openSelectedGitHubItemInBrowser() }
    case .return where press.modifiers.contains(.command):
      if press.phase == .down, pick == nil { openSelectedGitHubItemAsTask() }
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

  /// 右の欄の項目・提案タブの棚と中身。
  private func handlePlaceKey(_ press: KeyPress) -> KeyPress.Result {
    if visibleTab == .automation { return automation.handlePlaceKey(press) }
    switch area {
    case .list: return .ignored
    case .pane(let stop): return handlePaneKey(press, stop)
    case .detail(let stop): return handleDetailKey(press, stop)
    }
  }

  private func handleDetailKey(_ press: KeyPress, _ stop: TaskDetailStop) -> KeyPress.Result {
    if press.key == .return, press.modifiers.contains(.command) {
      if press.phase == .down, let task = selectedTask { openAgent(forTask: task.id) }
      return .handled
    }
    switch press.key {
    case .upArrow: moveField(-1)
    case .downArrow: moveField(1)
    case .leftArrow, .rightArrow:
      // 押し続けたキーリピートで、ステータスが完了に入って待ちを消さない。
      if stop == .field(.status), press.phase != .down { break }
      if press.key == .rightArrow {
        changeValue(1)
      } else if !changeValue(-1) {
        leaveDetail()
      }
    case .return: activate(stop, press)
    case .space:
      if press.phase == .down, let task = selectedTask { toggleDone(task.id) }
    case _ where Self.isCommandBackspace(press):
      if press.phase == .down, let task = selectedTask { delete(task.id) }
    case _ where Self.isBackspace(press):
      // 押し続けたキーリピートで、焦点が移った先の結び付きまで外さない。
      guard case .link(let item) = stop else { return .ignored }
      if press.phase == .down { unlink(item) }
    case .escape: leaveDetail()
    default: return .ignored
    }
    return .handled
  }

  /// 右の欄の止まる場所の ↵。押し続けたキーリピートでは繰り返さない（同じページを何度も開かない・開閉を繰り返さない）。
  private func activate(_ stop: TaskDetailStop, _ press: KeyPress) {
    guard press.phase == .down else { return }
    switch stop {
    case .field(let field):
      if field.isText { beginEditing() }
    case .conversation: focusConversationTab()
    case .agent: focusAgentTab()
    case .condition(let part): toggleConditionPart(part)
    case .link(let item): openLink(item)
    case .addLink: beginPickingItem()
    }
  }

  /// 右の欄の項目。↵（期限の項目以外）・⌘L・⌘↵・⌘O は、行の「タスクにする」「結び付ける」「タスクにして開く」
  /// 「ブラウザで開く」と同じ。
  private func handlePaneKey(_ press: KeyPress, _ stop: TaskGitHubPaneStop) -> KeyPress.Result {
    switch press.key {
    case .upArrow: movePaneStop(-1)
    case .downArrow: movePaneStop(1)
    case .leftArrow: if !changePaneValue(-1) { leavePane() }
    case .rightArrow: changePaneValue(1)
    case .space:
      if press.phase == .down, stop == .assign { togglePaneAssign() }
    case .return where press.modifiers.contains(.command):
      if press.phase == .down { openSelectedGitHubItemAsTask() }
    case .return:
      guard press.phase == .down else { break }
      if stop == .due {
        beginPaneDue()
      } else if let row = selectedGitHubRow {
        makeTask(row)
      }
    case _ where Self.isLinkKey(press):
      if press.phase == .down { linkSelectedGitHubItem() }
    case _ where Self.isOpenInBrowserKey(press):
      if press.phase == .down { openSelectedGitHubItemInBrowser() }
    case .escape: leavePane()
    default: return .ignored
    }
    return .handled
  }

  /// 文字の項目の編集欄。1 行の項目の ↵ は `onSubmit` が受けて確定し（押し続けたキーリピートは確定の入口が
  /// 捨てる——押し続けて確定と編集の開始を繰り返さない）、esc で取り消す。⌘↵ も確定で、GitHub タブの右の欄の
  /// 期限ではタスクにして開かない。複数行の項目は ↵ を改行に使う（リピートも改行）ので、esc で確定し、⌘↵ では
  /// 何もしない。
  private func handleEditKey(_ press: KeyPress) -> KeyPress.Result {
    guard let draft else { return .ignored }
    switch press.key {
    case .escape: endEditing(commit: draft.isMultiline)
    case .return where press.modifiers.contains(.command):
      if !draft.isMultiline { endEditing(commit: true) }
    default: return .ignored
    }
    return .handled
  }

  /// 押している修飾キーが無いか。実機の矢印キーは numericPad と function の修飾を伴って届くので、
  /// 修飾の集合が空かでは判定しない。
  static func isUnmodified(_ press: KeyPress) -> Bool {
    press.modifiers.isDisjoint(with: [.command, .option, .control, .shift])
  }

  /// ⌘⌫。
  static func isCommandBackspace(_ press: KeyPress) -> Bool {
    press.modifiers.contains(.command) && press.key == .backspace
  }

  /// ブラウザで開く（⌘O）。
  static func isOpenInBrowserKey(_ press: KeyPress) -> Bool {
    press.modifiers.contains(.command) && press.modifiers.isDisjoint(with: [.option, .control])
      && press.key.character.lowercased() == "o"
  }

  /// 結び付ける（⌘L）。
  private static func isLinkKey(_ press: KeyPress) -> Bool {
    press.modifiers.contains(.command) && press.modifiers.isDisjoint(with: [.option, .control])
      && press.key.character.lowercased() == "l"
  }

  /// 修飾なしの ⌫。
  private static func isBackspace(_ press: KeyPress) -> Bool {
    isUnmodified(press) && press.key == .backspace
  }
}

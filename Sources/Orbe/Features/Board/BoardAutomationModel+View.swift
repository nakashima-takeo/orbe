import SwiftUI

/// ビューが読む値。ビューは自動化そのものに触れず、これらの値と立ち位置だけを読む。
extension BoardAutomationModel {
  /// 一覧の行の値。
  func summary(_ id: Int, text: AutomationText, now: Date) -> BoardAutomationSummary? {
    guard let automation = store.automation(id) else { return nil }
    return BoardAutomationSummary(
      automation, text: text, next: runner.nextRunAt(automation, now: now))
  }

  /// 詳細の値。
  func detail(_ id: Int, text: AutomationText, now: Date) -> BoardAutomationDetailValue? {
    guard let automation = store.automation(id) else { return nil }
    return BoardAutomationDetailValue(
      automation, text: text, running: { self.runner.isRunning(id, $0) },
      open: store.shelvedProposals(of: id).count, next: runner.nextRunAt(automation, now: now))
  }

  /// 選ばれている部品のカードの値。部品が選ばれていなければ nil。
  func card(text: AutomationText, now: Date) -> BoardAutomationPartValue? {
    guard let automation = selectedAutomation, let part = selectedPart else { return nil }
    return BoardAutomationPartValue(
      automation, part: part, text: text, running: runner.isRunning(automation.id, part),
      next: runner.nextRunAt(automation, part: part, now: now),
      open: store.shelvedProposals(of: automation.id).count)
  }

  /// 描くときの文。暦の今日は描くときの今から導く（開きっぱなしの画面で日をまたいでも「今日」が古くならない）。
  func text(_ l10n: LocalizationStore, now: Date) -> AutomationText {
    let timeZone = runner.calendar().timeZone
    return AutomationText(l10n: l10n, today: .today(now, timeZone: timeZone), timeZone: timeZone)
  }

  /// フッターの左に出すキー。欄では送る・一覧へ移るキー（一覧が空なら移る先が無いので出さない）、一覧では選んだ自動化で効く
  /// キー、地図では選んでいる段で効くキー、サブメニューを開いている間はその中のキー。
  var hints: [BoardKeyHint] {
    if notifyCursor != nil {
      return [
        BoardKeyHint("↑↓", .boardHintSelect), BoardKeyHint("↵", .boardHintChoose),
        BoardKeyHint("←", .boardHintBack),
      ]
    }
    if selectedUnreadable != nil {
      let delete = BoardAutomationHand.Operation.delete
      return [
        BoardKeyHint("↑↓", .boardHintSelect), BoardKeyHint(delete.key, delete.title(paused: false)),
      ]
    }
    guard let selectedAutomation else {
      return [BoardKeyHint("↵", .boardAskHint)]
        + (ids.isEmpty ? [] : [BoardKeyHint("↓", .boardHintToList)])
    }
    let paused = selectedAutomation.paused
    func hand(_ operation: BoardAutomationHand.Operation) -> BoardKeyHint {
      BoardKeyHint(operation.key, operation.title(paused: paused))
    }
    switch selectedMapStop {
    case .notify:
      return [
        BoardKeyHint("↑↓", .boardHintParts), BoardKeyHint("↵", .boardHintChangeNotify),
        BoardKeyHint("←", .boardHintToList),
      ]
    case .part:
      return [
        BoardKeyHint("↑↓", .boardHintParts), hand(.flow(.part)),
        BoardKeyHint("←", .boardHintToList),
      ]
    case nil:
      return [
        BoardKeyHint("↑↓", .boardHintSelect), BoardKeyHint("↵", .boardHintSeeParts),
        hand(.flow(.ends)), hand(.togglePause), hand(.delete),
      ]
    }
  }
}

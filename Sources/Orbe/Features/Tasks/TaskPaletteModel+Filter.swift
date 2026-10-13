import Foundation

/// タスクのタブの絞り込み・並び・絞り込みのメニュー。絞り込みを変えたら先頭の行を選び（入力を変えたときと同じ）、
/// 並びを変えたら選択を同一性で保って見える所へスクロールする。どれも編集中なら確定してから行う。
extension TaskPaletteModel {
  /// 状態の札のクリック。
  func toggleState(_ state: TaskItem.DisplayState) {
    changeFilter { $0.states.formSymmetricDifference([state]) }
  }

  /// 絞り込みのメニューの行のクリック（workspace。nil は「なし」）。メニューは開いたまま。
  func toggleWorkspaceFilter(_ id: UUID?) {
    changeFilter { $0.workspaces.formSymmetricDifference([id]) }
  }

  func togglePriorityFilter(_ priority: TaskItem.Priority) {
    changeFilter { $0.priorities.formSymmetricDifference([priority]) }
  }

  func toggleDueFilter(_ bucket: TaskDueBucket) {
    changeFilter { $0.dues.formSymmetricDifference([bucket]) }
  }

  /// 列の見出しのクリック。
  func setSort(_ column: TaskPaletteSort.Column) {
    leaveEditingForAction()
    area = .list
    sort = sort.tapped(column)
    reconcile()
    taskList.follow()
  }

  /// 絞り込みのドロップダウンのクリック。開いているメニューのドロップダウンなら閉じる。
  func toggleFilterMenu(_ kind: TaskPaletteFilterKind) {
    leaveEditingForAction()
    area = .list
    openFilterMenu = openFilterMenu == kind ? nil : kind
  }

  /// メニューの外のクリック・esc。
  func closeFilterMenu() {
    openFilterMenu = nil
  }

  private func changeFilter(_ change: (inout TaskPaletteFilter) -> Void) {
    leaveEditingForAction()
    area = .list
    change(&filter)
    reconcile()
    selectFirstTask()
  }
}

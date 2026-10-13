import Foundation

/// agent に任せる（入力の行き先の ⌘↵）。打った文を秘書の係へ渡し、Home で起こした claude に最初の入力として届ける。
extension TaskPaletteModel {
  /// 入力の行き先が持つタイトル（入力が無い・選ぶ状態なら nil）。
  var addTitle: String? {
    visibleTab == .tasks ? TaskPaletteRows.addTitle(rowsInput) : nil
  }

  /// 打った文を agent に任せる。受けたら入力欄を空にする（受けると画面は閉じるが、閉じるかは見せ方の結果で、ここは
  /// 頼らない）。受けなければ入力をそのまま残し、理由を出す（空の頼みは黙る）。
  func askWithQuery() {
    guard let title = addTitle else { return }
    leaveEditingForAction()
    switch onAskSecretary(.text(title)) {
    case nil: query = ""
    case .claudeMissing: error = .secretaryClaude
    case .unavailable: error = .secretaryUnavailable
    case .empty: break
    }
  }

  /// 行き先の段の右端の言葉（「未着手 · 中 · <workspace>」）。足すタスクの値（`TaskDraft` の既定の
  /// ステータスと優先度）と、範囲で決まる workspace から出す。
  func destinationPlace(_ l10n: LocalizationStore) -> String {
    let draft = TaskDraft(title: "")
    let status: L10nKey =
      draft.status == .inProgress ? .taskPaletteSectionInProgress : .taskPaletteSectionTodo
    let priority: L10nKey =
      switch draft.priority {
      case .high: .taskPalettePriorityHigh
      case .medium: .taskPalettePriorityMedium
      case .low: .taskPalettePriorityLow
      }
    return [
      l10n.string(status), l10n.string(priority),
      addedWorkspace?.name ?? l10n.string(.taskPaletteDestinationNoWorkspace),
    ].joined(separator: " · ")
  }
}

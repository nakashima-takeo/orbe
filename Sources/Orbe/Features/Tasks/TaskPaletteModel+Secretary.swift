import Foundation

/// agent に任せる（入力の行き先の ⌘↵）。打った文を秘書の係へ渡し、Home で起こした claude に最初の入力として届ける。
extension TaskPaletteModel {
  /// 入力の行き先が持つタイトル（入力が無い・選ぶ状態なら nil）。
  var addTitle: String? {
    visibleTab == .tasks ? TaskPaletteRows.addTitle(rowsInput) : nil
  }

  /// 打った文を agent に任せる。受けたら入力欄を空にする（受けると窓が画面を閉じるが、ここはそれに頼らない）。
  /// 受けなければ入力をそのまま残し、理由を出す（空の頼みは黙る）。
  func askWithQuery() {
    guard let title = addTitle else { return }
    leaveEditingForAction()
    switch onAskSecretary(title) {
    case nil: query = ""
    case .claudeMissing: error = .secretaryClaude
    case .unavailable: error = .secretaryUnavailable
    case .empty: break
    }
  }
}

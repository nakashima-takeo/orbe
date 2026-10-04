import Foundation

/// ⇥ で巡回する起動先（検出した agent と shell）の選択。
extension WorktreePaletteModel {
  /// 検出済み agent から巡回対象を組む。既定の agent を先頭に、shell をその直後に、残りの agent を
  /// 検出順に並べる。既定が検出に無ければ検出順の先頭を既定とする。初期選択は先頭。
  func setTargets(agents: [AgentCLI], defaultCommand: String?) {
    let defaultAgent = agents.first { $0.command == defaultCommand } ?? agents.first
    let rest = agents.filter { $0 != defaultAgent }.map(WorktreePaletteTarget.agent)
    targets = (defaultAgent.map { [.agent($0)] } ?? []) + [.shell] + rest
    selectedTargetIndex = 0
  }

  /// 既定の agent（「既定」の札を付ける起動先）。agent が 1 つも無ければ nil。
  var defaultTarget: WorktreePaletteTarget? {
    guard case .agent = targets.first else { return nil }
    return targets.first
  }

  /// ⇥ で選択起動先を巡回する。
  func cycleTarget() {
    guard !targets.isEmpty else { return }
    selectedTargetIndex = (selectedTargetIndex + 1) % targets.count
  }

  /// 起動先のボタンのクリック。
  func chooseTarget(at index: Int) {
    guard !isLocked, targets.indices.contains(index) else { return }
    selectedTargetIndex = index
  }

  /// 選択中の起動先（targets が空なら nil）。
  var selectedTarget: WorktreePaletteTarget? {
    targets.indices.contains(selectedTargetIndex) ? targets[selectedTargetIndex] : nil
  }

  /// フッターに出す起動先名。
  var selectedTargetName: String { selectedTarget?.name ?? "" }
}

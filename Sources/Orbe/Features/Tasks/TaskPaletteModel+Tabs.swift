import Foundation

/// ヘッダーのタブ（⇧⇥ で並びの順に巡る）。
enum TaskPaletteTab: Equatable {
  case tasks, github, automation

  var next: TaskPaletteTab {
    switch self {
    case .tasks: .github
    case .github: .automation
    case .automation: .tasks
    }
  }
}

/// タブの振り分け（見えているタブ・入力・入力モダリティ・入力欄のクリック）。受信タブの値は `automation` が持つ。
extension TaskPaletteModel {
  /// 今見えているタブ。選ぶ状態ならその方向で、無ければ保存したタブ。行・キー・フッター・本体の切り替えは
  /// すべてこれを見る。
  var visibleTab: TaskPaletteTab {
    switch pick {
    case .task: .tasks
    case .item: .github
    case nil: tab
    }
  }

  /// ヘッダーの入力（今見えている一覧の絞り込み。タスクのタブでは追加するタイトルも兼ねる）。
  var query: String {
    get {
      switch visibleTab {
      case .tasks: taskList.query
      case .github: gitHubList.query
      case .automation: automation.query
      }
    }
    set {
      guard newValue != query else { return }
      switch visibleTab {
      case .tasks: taskList.query = newValue
      case .github: gitHubList.query = newValue
      case .automation: automation.query = newValue
      }
      queryChanged()
    }
  }

  /// 実マウス移動（`MouseMovedDetector`）が `.pointer` へ落とす。
  var inputModality: InputModality {
    get {
      switch visibleTab {
      case .tasks: taskList.modality
      case .github: gitHubList.modality
      case .automation: automation.modality
      }
    }
    set {
      switch visibleTab {
      case .tasks: taskList.modality = newValue
      case .github: gitHubList.modality = newValue
      case .automation: automation.modality = newValue
      }
    }
  }

  /// 入力欄のクリック。右の欄・棚・中身から一覧へ戻る。
  func returnToField() {
    if visibleTab == .automation { automation.showProposals() } else { leaveDetail() }
  }

  /// 入力が変わったら、先頭の行（タスクのタブで入力があれば入力の行き先）を選ぶ。
  private func queryChanged() {
    error = nil
    switch visibleTab {
    case .tasks: taskList.selectFirst(in: selectableIDs)
    case .github: gitHubList.selectFirst(in: gitHubSelectableIDs)
    case .automation: break
    }
    discardStaleDrag()
  }
}

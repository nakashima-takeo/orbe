import SwiftUI

/// ボードの自動化への手の操作（流す・止める ⇄ 再開〔自動化かノード〕・削除）。居場所ごとのキーとの対応・キーの表示・名前・断りをここだけが
/// 決める——キーを変えたとき、フッターの表示やカードのボタンだけが嘘になる写しを残さないため。
enum BoardAutomationHand {
  /// 流す先。ノードまでなら、流す先のノードは地図の「選ばれているノード」から解く。
  enum Reach: Equatable {
    /// 終わりのノードすべて。
    case ends
    /// 選ばれているノード。
    case node
  }

  enum Operation: Equatable {
    case flow(Reach)
    /// 自動化を止める ⇄ 再開。
    case togglePause
    /// 選ばれているノード自身を止める ⇄ 再開。
    case toggleNodePause
    case delete

    var key: String {
      switch self {
      case .flow: "⌘↵"
      case .togglePause, .toggleNodePause: "space"
      case .delete: "⌘⌫"
      }
    }

    /// 止める ⇄ 再開は、止めているか（ノードならノード自身の印）で名前が替わる。
    func title(paused: Bool) -> L10nKey {
      switch self {
      case .flow(.ends): .automationRunNow
      case .flow(.node): .automationFlowToSelected
      case .togglePause, .toggleNodePause: paused ? .automationResume : .automationPause
      case .delete: .automationDelete
      }
    }
  }

  /// キーが操作に当たった。押し続けたキーリピートは握るが何もしない（取り消せない操作を繰り返さない）。
  enum Stroke: Equatable {
    case press(Operation)
    case held
  }

  /// 断り。行き違い（消えていた等）は黙り、断るのは道の重なる流しがある間の流すだけ。
  enum Refusal: Equatable {
    case flowing

    var message: L10nKey { .automationErrRunning }
  }

  /// 一覧では ⌘↵＝終わりまで流す（今すぐ実行）、space＝止める ⇄ 再開、⌘⌫＝削除。地図のノードの段では ⌘↵＝選ばれているノードまで
  /// 流す、space＝選ばれているノードを止める ⇄ 再開。他のキーと場所は nil。
  static func stroke(_ press: KeyPress, at place: BoardAutomationModel.Place) -> Stroke? {
    let commandOnly =
      press.modifiers.contains(.command)
      && press.modifiers.isDisjoint(with: [.option, .control, .shift])
    let operation: Operation
    switch (place, press.key) {
    case (.list, .return) where commandOnly: operation = .flow(.ends)
    case (.list, .space): operation = .togglePause
    case (.list, .backspace) where press.modifiers.contains(.command): operation = .delete
    case (.map, .return) where commandOnly: operation = .flow(.node)
    case (.map, .space): operation = .toggleNodePause
    default: return nil
    }
    return press.phase == .down ? .press(operation) : .held
  }

  /// 走らせ役へ通す。`nodeId` はノードまで流す・ノードを止めるときの先（無ければ何もしない）。
  static func perform(
    _ operation: Operation, on automation: Automation, nodeId: AutomationNodeID?,
    runner: AutomationRunner
  ) -> Refusal? {
    switch operation {
    case .flow(let reach):
      let target: AutomationFlow.Target
      switch reach {
      case .ends: target = .ends
      case .node:
        guard let nodeId else { return nil }
        target = .node(nodeId)
      }
      do throws(AutomationError) {
        try runner.flow(automation.id, to: target)
      } catch {
        if case .flowing = error { return .flowing }
      }
    case .togglePause:
      _ = try? runner.pause(automation.id, !automation.paused)
    case .toggleNodePause:
      guard let nodeId, automation.graph.node(nodeId) != nil else { return nil }
      _ = try? runner.pause(automation.id, nodeId: nodeId, !automation.state(nodeId).paused)
    case .delete:
      try? runner.delete(automation.id)
    }
    return nil
  }
}

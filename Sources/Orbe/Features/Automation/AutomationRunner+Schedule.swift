import Foundation

/// 番人の上のノードの今（走っているか、次に予定で回る時刻）と、前の契機の印・数え始めの引き継ぎ。
/// 次に予定で回る時刻は、番人に最後に返した数え始めから数える。
extension AutomationRunner {
  /// どれかのノードが走っているか。
  func isRunning(_ id: Int) -> Bool {
    store.automation(id)?.graph.nodes.contains { isRunning(id, $0.id) } ?? false
  }

  func isRunning(_ id: Int, _ nodeId: AutomationNodeID) -> Bool {
    scheduler.isRunning(id: Self.key(id, nodeId))
  }

  /// `now`（渡さなければ走らせ役の今）から見て、どれかのノードが次に予定で回る時刻（実効で止めたノードは数えない）。
  func nextRunAt(_ automation: Automation, now: Date? = nil) -> Date? {
    automation.graph.nodes.compactMap { nextRunAt(automation, nodeId: $0.id, now: now) }.min()
  }

  /// ノードが次に予定で回る時刻。実効で止めた・予定の無いノードは nil。過ぎていれば `now` 以前の時刻を返す。
  func nextRunAt(_ automation: Automation, nodeId: AutomationNodeID, now: Date? = nil) -> Date? {
    guard let node = automation.graph.node(nodeId), !automation.halted(nodeId),
      case .scheduled(let timing) = node.entity.trigger
    else { return nil }
    let anchor = anchors[Self.key(automation.id, nodeId)] ?? automation.state(nodeId).anchor
    switch timing.next(after: anchor, deadline: nil, now: now ?? self.now(), calendar: calendar()) {
    case .run(let date): return date
    case .expire: return nil
    }
  }

  /// 走らせ役 `other` が持つ、自動化 `id` の各ノードの数え始めと、前の契機の印を、この走らせ役のものにする（番人に載せる前に呼ぶ）。
  /// 数え始めは `other` が番人に今返すはずの値（`anchor(_:_:)`）——`other` で走っている契機は、結果を残さずに終わったものとする。
  func inherit(_ id: Int, from other: AutomationRunner) {
    for node in other.store.automation(id)?.graph.nodes ?? [] {
      let key = Self.key(id, node.id)
      marks[key] = other.marks[key]
      anchors[key] = other.anchor(id, node.id)
    }
  }
}

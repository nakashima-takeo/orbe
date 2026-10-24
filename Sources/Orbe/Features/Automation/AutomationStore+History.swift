import Foundation

/// 過去の回の記録のページ読み。メモリは部品ごとの直近だけを持ち、過去は DB から読む。
extension AutomationStore {
  static let historyPage = 20
  static let historyPageLimit = 100

  /// 回の記録の 1 ページ。
  struct History {
    /// 新しい順。鍵は部品の今の鍵（部品の台帳から。定義を読めない自動化でも引ける）。
    let runs: [AutomationKeyedRecord]
    /// 続きがあれば、次のページを読むときに `before` に渡す記録の ID。
    let next: Int?
  }

  /// 自動化の回の記録を新しい順に `limit` 件（既定 20・上限 100）。`nodeKey` を渡せばその部品だけ。`before` は前のページの `next`。
  func history(of id: Int, nodeKey key: String?, before: Int?, limit: Int?) throws(AutomationError)
    -> History
  {
    let limit = limit ?? Self.historyPage
    guard (1...Self.historyPageLimit).contains(limit) else {
      throw .invalid("limit: must be 1 to \(Self.historyPageLimit)")
    }
    let nodeIds: [AutomationNodeID]
    if let automation = automation(id) {
      if let key {
        guard let node = automation.graph.node(key: key) else { throw .nodeNotFound(id, key) }
        nodeIds = [node.id]
      } else {
        nodeIds = automation.graph.nodes.map(\.id)
      }
    } else if let broken = unreadable.first(where: { $0.id == id }) {
      guard key == nil else { throw .unreadable(id, broken.reason) }
      nodeIds = broken.nodeIds
    } else {
      throw .automationNotFound(id)
    }
    let found = try read { try $0.records(of: nodeIds, before: before, limit: limit + 1) }
    let page = Array(found.prefix(limit))
    return History(runs: page, next: found.count > limit ? page.last?.record.id : nil)
  }
}

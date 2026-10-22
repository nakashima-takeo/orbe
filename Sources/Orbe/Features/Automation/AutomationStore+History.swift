import Foundation

/// 過去の回の記録のページ読み。メモリは部品ごとの直近だけを持ち、過去は DB から読む。
extension AutomationStore {
  static let historyPage = 20
  static let historyPageLimit = 100

  /// 回の記録の 1 ページ。
  struct History {
    /// 新しい順。
    let runs: [AutomationKeyedRun]
    /// 続きがあれば、次のページを読むときに `before` に渡す記録の ID。
    let next: Int?
    /// 部品の今の鍵（部品の台帳から。定義を読めない自動化でも引ける）。
    let keys: [AutomationPartID: String]
  }

  /// 自動化の回の記録を新しい順に `limit` 件（既定 20・上限 100）。`part` を渡せばその部品だけ。`before` は前のページの `next`。
  func history(of id: Int, part key: String?, before: Int?, limit: Int?) throws(AutomationError)
    -> History
  {
    let limit = limit ?? Self.historyPage
    guard (1...Self.historyPageLimit).contains(limit) else {
      throw .invalid("limit: must be 1 to \(Self.historyPageLimit)")
    }
    let parts: [AutomationPartID]
    if let automation = automation(id) {
      if let key {
        guard let node = automation.graph.node(key: key) else { throw .partNotFound(id, key) }
        parts = [node.id]
      } else {
        parts = automation.graph.nodes.map(\.id)
      }
    } else if let broken = unreadable.first(where: { $0.id == id }) {
      guard key == nil else { throw .unreadable(id, broken.reason) }
      parts = broken.parts
    } else {
      throw .automationNotFound(id)
    }
    let (found, keys) = try read {
      (try $0.records(among: parts, before: before, limit: limit + 1), try $0.partKeys(of: id))
    }
    let page = found.prefix(limit).map { AutomationKeyedRun(part: $0.part, record: $0.record) }
    return History(
      runs: page, next: found.count > limit ? page.last?.record.id : nil, keys: keys)
  }
}

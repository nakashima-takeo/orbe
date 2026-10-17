import Foundation

/// 溜まりの規則。行の本文を持たない目録に対する計算で、積む行・取る行・捨てる行を選ぶだけ。DB を読み書きするのは呼び手。
enum AutomationInbox {
  /// 行を依頼文に入れる agent が 1 回で取る件数と大きさの和（バイト）の上限。
  static let batchCount = 100
  static let batchBytes = 256 << 10

  /// 行の元になった取得の部品と項目。
  struct Origin: Equatable {
    /// 取得の部品の鍵。
    let part: String
    /// その部品が出したままの項目の id（溜まりの行の id の接頭を付ける前）。前回の出力と照らす。
    let item: String
    let link: String
  }

  /// 溜まりの行の目録。
  struct Row: Equatable {
    /// Orbe が積んだときに付けた通し番号。大きいほど後に届いた。
    let seq: Int
    let id: String
    let origin: Origin?
    /// 行の JSON の UTF-8 のバイト数（積むときに数える）。
    let size: Int
    /// 積んだ時刻。古さの上限はここから数える。
    let arrivedAt: Date
  }

  /// 届いた行。今の溜まりのどれより新しい。
  struct Arrival: Equatable {
    let id: String
    let origin: Origin?
    let size: Int
  }

  struct Push: Equatable {
    /// 積む行（届いた順）。
    let stacked: [Arrival]
    /// 同じ id の行が届いて置き換わる、今の行の通し番号。
    let replaced: [Int]
    /// 判定の部品へ届いたのに出どころが無く、捨てた行。
    let unsourced: [Arrival]
    /// 件数の上限で捨てる、今の行の通し番号（古い順）。
    let overflowed: [Int]
    /// 件数の上限で捨てた、届いた行。
    let overflowedArrivals: [Arrival]
    /// 1 行以上届いて、出どころが無いので全部捨てた——上流の回の失敗にする。
    let upstreamFailed: Bool
  }

  struct Take: Equatable {
    /// 取る行の通し番号（古い順）。空なら呼び手は手段を起こさない。
    let taken: [Int]
    /// 捨てる行（通し番号の順）。
    let dropped: [Drop]
  }

  struct Drop: Equatable {
    let seq: Int
    let reason: Reason
  }

  enum Reason: Equatable {
    /// 今の集合の取得の部品から来て、その項目がもう前回の出力に無い。
    case leftCurrentSet
    /// 届いてから古さの上限を過ぎた。
    case expired
    /// 出どころのリンクに候補がある（判定の部品だけ）。
    case proposed
    /// 同じリンクの、より新しい行がある（判定の部品だけ）。
    case sameLink
  }

  /// `node` の溜まり（`rows`）に `arrivals` を積む。届いた行の中で同じ id は後の方だけ、判定の部品へは出どころのある行だけを
  /// 積み、積む行と同じ id の今の行は置き換わる。件数の上限があれば、超えた分を古い行から捨てる。捨てた行は置き換えない。
  static func push(_ arrivals: [Arrival], into node: AutomationGraph.Node, holding rows: [Row])
    -> Push
  {
    let judges = node.role == .judge
    let unsourced = judges ? arrivals.filter { $0.origin == nil } : []
    let sourced = judges ? arrivals.filter { $0.origin != nil } : arrivals
    var last: [String: Int] = [:]
    for (index, arrival) in sourced.enumerated() { last[arrival.id] = index }
    var stacked = sourced.indices.filter { last[sourced[$0].id] == $0 }.map { sourced[$0] }
    let ids = Set(stacked.map(\.id))
    let replaced = rows.filter { ids.contains($0.id) }.map(\.seq).sorted()
    let kept = rows.filter { !ids.contains($0.id) }.map(\.seq).sorted()
    var overflowed: [Int] = []
    var overflowedArrivals: [Arrival] = []
    if let maxItems = node.part.inboxLimit?.maxItems, kept.count + stacked.count > maxItems {
      let excess = kept.count + stacked.count - maxItems
      overflowed = Array(kept.prefix(excess))
      let newExcess = excess - overflowed.count
      overflowedArrivals = Array(stacked.prefix(newExcess))
      stacked.removeFirst(newExcess)
    }
    return Push(
      stacked: stacked, replaced: replaced, unsourced: unsourced, overflowed: overflowed,
      overflowedArrivals: overflowedArrivals,
      upstreamFailed: !arrivals.isEmpty && sourced.isEmpty)
  }

  /// 取るときの事情。
  struct Context {
    let graph: AutomationGraph
    /// 取得の部品の鍵ごとの、前回の出力の項目 id（`Origin.item` と同じ、接頭の無い id）。無い部品は空。
    let lastOutputs: [String: Set<String>]
    /// リンクに候補があるか。
    let proposed: (String) -> Bool
    let now: Date
  }

  /// `node` が溜まり（`rows`）から取る行を選ぶ。集合外 → 古さ → 候補あり → 同じリンクの古い方 の順に、最初に当たった理由で捨て、
  /// 残りを古い順に取る。行を依頼文に入れる agent だけ 1 回の上限で止め（先頭の 1 件だけで超えるならその 1 件）、ほかは全部取る。
  static func take(by node: AutomationGraph.Node, from rows: [Row], in context: Context) -> Take {
    var dropped: [Drop] = []
    var remaining: [Row] = []
    for row in rows.sorted(by: { $0.seq < $1.seq }) {
      if let reason = reason(toDrop: row, by: node, in: context) {
        dropped.append(Drop(seq: row.seq, reason: reason))
      } else {
        remaining.append(row)
      }
    }
    if node.role == .judge {
      var newest: [String: Int] = [:]
      for row in remaining { if let link = row.origin?.link { newest[link] = row.seq } }
      let stale = Set(
        remaining.filter { row in row.origin.map { newest[$0.link] != row.seq } ?? false }
          .map(\.seq))
      dropped += stale.map { Drop(seq: $0, reason: .sameLink) }
      remaining.removeAll { stale.contains($0.seq) }
      dropped.sort { $0.seq < $1.seq }
    }
    let taken = node.putsRowsInPrompt ? batch(remaining) : remaining
    return Take(taken: taken.map(\.seq), dropped: dropped)
  }

  /// 出どころの取得の部品がグラフに無いか、今の集合でなければ、集合外では捨てない。
  private static func reason(toDrop row: Row, by node: AutomationGraph.Node, in context: Context)
    -> Reason?
  {
    if let origin = row.origin, context.graph.node(origin.part)?.role == .fetch(.currentSet),
      context.lastOutputs[origin.part]?.contains(origin.item) != true
    {
      return .leftCurrentSet
    }
    if let hours = node.part.inboxLimit?.maxAgeHours,
      context.now.timeIntervalSince(row.arrivedAt) > TimeInterval(hours) * 3600
    {
      return .expired
    }
    if node.role == .judge, let link = row.origin?.link, context.proposed(link) {
      return .proposed
    }
    return nil
  }

  private static func batch(_ rows: [Row]) -> [Row] {
    var taken: [Row] = []
    var bytes = 0
    for row in rows {
      guard taken.count < batchCount, taken.isEmpty || bytes + row.size <= batchBytes else { break }
      taken.append(row)
      bytes += row.size
    }
    return taken
  }
}

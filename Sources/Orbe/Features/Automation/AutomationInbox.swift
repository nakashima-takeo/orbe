import Foundation

/// 受け手の読み。上流から引いた行（`AutomationDatabase.rows`）に受け手の取り方を掛け、取る行・捨てる行・読んだ位置の進め先を
/// 選ぶだけの計算。DB を読み書きするのは呼び手。
enum AutomationInbox {
  /// 行を依頼文に入れる agent が 1 回で取る件数と大きさの和（バイト）の上限。
  static let batchCount = 100
  static let batchBytes = 256 << 10

  /// 出す側の表。
  enum Table: Equatable {
    case item
    case event
  }

  /// 出どころ——引き継ぎをたどった先の、取得の部品が出した行。候補のリンクと本文はいつもここから取る。
  struct Origin: Equatable {
    let part: AutomationPartID
    /// 項目なら今の版、出来事ならその出来事。
    let row: AutomationRowRef
    /// 出どころの行の欄（`id` は書かれた id）。
    let item: AutomationItem
  }

  /// 上流の行 1 つ。
  struct Row: Equatable {
    /// 上流の部品（つながり）。
    let edge: AutomationPartID
    let table: Table
    let seq: Int
    /// 回の履歴が指す行（項目は版）。
    let ref: AutomationRowRef
    /// 下流が引き継ぐ参照（項目か出来事）。
    let source: AutomationSourceRef
    /// 下流へ渡す id。
    let id: String
    /// 下流へ渡す 1 行。
    let text: String
    /// 項目は有効になった時刻、出来事は作られた時刻。古さはここから数える。
    let at: Date
    let origin: Origin?
    /// 読んだ位置より後か（take が all の行は、前の回までに読んだ行も載る）。
    let unread: Bool
  }

  enum Reason: Equatable {
    /// 出どころが無い（判定の部品だけ）。
    case unsourced
    /// 古さの上限を過ぎた。
    case expired
    /// 出どころのリンクに候補がある（判定の部品だけ）。
    case proposed
    /// 同じリンクの、より新しい行がある（判定の部品だけ）。
    case sameLink
    /// 同じ下流へ渡す id の、より新しい行がある。
    case replaced
    /// 件数の上限を超えた。
    case overflow

    /// 回の履歴の扱いの名。
    var how: String {
      switch self {
      case .unsourced: "unsourced"
      case .expired: "expired"
      case .proposed: "proposed"
      case .sameLink: "sameLink"
      case .replaced: "replaced"
      case .overflow: "overflow"
      }
    }
  }

  struct Drop: Equatable {
    let row: Row
    let reason: Reason
  }

  /// 読んだ位置の進め先（つながりと表ごと）。
  struct Reach: Equatable {
    let edge: AutomationPartID
    let table: Table
    let seq: Int
  }

  /// 読んだもの。
  struct Read: Equatable {
    /// 取る行（古い順）。
    var taken: [Row]
    /// 捨てる行（読んだ位置より後の行だけ。前の回までに読んだ行は黙って除く）。
    var dropped: [Drop]
    /// 読んだ位置の進め先。
    var reach: [Reach]
    /// 1 回の上限で切った（切った残りは読んでいないので、同じ契機でもう 1 回読む）。
    var cut: Bool
    /// 読む前に期限で消えた出来事の数（呼び手が `reach` から数えて足す）。
    var lapsed = 0
  }

  /// つながりごとの、読む上限の番号（読んだ位置を上限まで進めてよいかを決める）。
  struct Ceiling: Equatable {
    let edge: AutomationPartID
    let item: Int
    let event: Int
  }

  /// 取るときの事情。
  struct Context {
    /// リンクに候補があるか。
    let proposed: (String) -> Bool
    let now: Date
    /// 1 回の上限を掛けるか（件数を数えるだけのときは掛けない）。
    let batch: Bool
  }

  /// `node` が `rows` から取る行を選ぶ。古さ → 判定だけの捨て方（出どころなし → 候補あり → 同じリンクの古い方）→ 同じ id の
  /// 古い方 → 件数の上限 の順に捨て、残りを古い順に取る。行を依頼文に入れる agent だけ、take が new の行に 1 回の上限を
  /// 掛け（先頭の 1 件だけで超えるならその 1 件）、切った残りは読まない。take が all の行は切らない（毎回全件の取り方なので）。
  static func read(
    by node: AutomationGraph.Node, _ rows: [Row], ceilings: [Ceiling], in context: Context
  ) -> Read {
    let edges = Dictionary(uniqueKeysWithValues: node.inputs.map { ($0.from, $0) })
    var (remaining, dropped) = filtered(rows.sorted(by: order), by: node, edges, context)
    var newestId: [String: Row] = [:]
    for row in remaining { newestId[row.id] = row }
    let replaced = remaining.filter { newestId[$0.id] != $0 }
    dropped += replaced.map { Drop(row: $0, reason: .replaced) }
    remaining.removeAll { replaced.contains($0) }
    if let maxItems = node.part.maxItems, remaining.count > maxItems {
      dropped += remaining.prefix(remaining.count - maxItems).map {
        Drop(row: $0, reason: .overflow)
      }
      remaining.removeFirst(remaining.count - maxItems)
    }
    let cutAt =
      context.batch && node.putsRowsInPrompt
      ? cut(remaining.filter { edges[$0.edge]?.take != .all }) : nil
    func inside(_ row: Row) -> Bool {
      guard let cutAt, edges[row.edge]?.take != .all else { return true }
      return order(row, cutAt)
    }
    return Read(
      taken: remaining.filter(inside),
      dropped: dropped.filter { $0.row.unread && inside($0.row) }.sorted { order($0.row, $1.row) },
      reach: reach(
        read: rows.filter(inside), left: rows.filter { $0.unread && !inside($0) }, ceilings),
      cut: cutAt != nil)
  }

  /// 古さで捨て、判定だけは出どころなし → 候補あり → 同じリンクの古い方で捨てる。残りと捨てた行（古い順）を返す。
  private static func filtered(
    _ rows: [Row], by node: AutomationGraph.Node, _ edges: [AutomationPartID: AutomationPartEdge],
    _ context: Context
  ) -> (remaining: [Row], dropped: [Drop]) {
    var remaining: [Row] = []
    var dropped: [Drop] = []
    let judge = node.role == .judge
    for row in rows {
      if let hours = edges[row.edge]?.maxAgeHours,
        context.now.timeIntervalSince(row.at) > TimeInterval(hours) * 3600
      {
        dropped.append(Drop(row: row, reason: .expired))
      } else if judge, row.origin == nil {
        dropped.append(Drop(row: row, reason: .unsourced))
      } else if judge, let link = row.origin?.item.link, context.proposed(link) {
        dropped.append(Drop(row: row, reason: .proposed))
      } else {
        remaining.append(row)
      }
    }
    guard judge else { return (remaining, dropped) }
    var newest: [String: Row] = [:]
    for row in remaining { if let link = row.origin?.item.link { newest[link] = row } }
    let stale = remaining.filter { row in row.origin.map { newest[$0.item.link] != row } ?? false }
    remaining.removeAll { stale.contains($0) }
    return (remaining, dropped + stale.map { Drop(row: $0, reason: .sameLink) })
  }

  /// 1 回の上限で切る行（古い順に件数と大きさの和が上限を超える最初の行）。切らなければ nil。
  private static func cut(_ rows: [Row]) -> Row? {
    var count = 0
    var bytes = 0
    for row in rows {
      guard count < batchCount, count == 0 || bytes + row.text.utf8.count <= batchBytes else {
        return row
      }
      count += 1
      bytes += row.text.utf8.count
    }
    return nil
  }

  /// 読んだ位置の進め先。読み残しの無いつながりと表は上限の番号まで（その間で読まなかった番号は、読む前に無効になった項目か
  /// 期限で消えた出来事）、読み残しがあれば読んだ最大の番号まで。
  private static func reach(read: [Row], left: [Row], _ ceilings: [Ceiling]) -> [Reach] {
    var reach: [Reach] = []
    for ceiling in ceilings {
      for table in [Table.item, .event] {
        let mine = { (row: Row) in row.edge == ceiling.edge && row.table == table }
        let seq =
          left.contains(where: mine)
          ? read.filter(mine).map(\.seq).max() ?? 0
          : table == .item ? ceiling.item : ceiling.event
        if seq > 0 { reach.append(Reach(edge: ceiling.edge, table: table, seq: seq)) }
      }
    }
    return reach
  }

  /// 古い順（同じ時刻は上流・表・番号の順）。表ごとの番号は時刻と同じ向きに増える。
  static func order(_ a: Row, _ b: Row) -> Bool {
    (a.at, a.edge.rawValue, a.table == .item ? 0 : 1, a.seq)
      < (b.at, b.edge.rawValue, b.table == .item ? 0 : 1, b.seq)
  }
}

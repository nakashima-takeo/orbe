import Foundation

/// 受け手の読み。上流から引いた行（`AutomationDatabase.rows`）に受け手の取り方を掛け、取る行・捨てる行・読んだ位置の進め先を
/// 選ぶだけの計算。DB を読み書きするのは呼び手。
enum AutomationIntake {
  /// 出す側の表。
  enum Table: Equatable {
    case item
    case event
  }

  /// 上流の行 1 つ。
  struct Row: Equatable {
    /// 上流のノード（つながり）。
    let from: AutomationNodeID
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
    /// 行の `link`（項目は今の版の）。無ければ nil。
    let link: String?
    /// 読んだ位置より後か（take が all の行は、前の回までに読んだ行も載る）。
    let unread: Bool
  }

  /// 捨てた行と理由（`lapsed` は読みでは出ない）。
  struct Drop: Equatable {
    let row: Row
    let reason: AutomationDrops.Reason
  }

  /// 読んだ位置の進め先（つながりと表ごと）。
  struct Reach: Equatable {
    let from: AutomationNodeID
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
    /// 読む前に期限で消えた出来事の数（呼び手が `reach` から数えて足す）。
    var lapsed = 0
  }

  /// つながりごとの、読む上限の番号（読んだ位置を上限まで進めてよいかを決める）。
  struct Ceiling: Equatable {
    let from: AutomationNodeID
    let seqs: AutomationSeqs
  }

  /// 取るときの事情。
  struct Context {
    /// リンクが、読むノード（判定）の判断待ちでない覚えている候補のリンクか。
    let closed: (String) -> Bool
    let now: Date
  }

  /// `node` が `rows` から取る行を選ぶ。古さ → 判定だけの捨て方（判断待ちでない覚えている候補のリンク）→ 同じ id の古い方 →
  /// 件数の上限 の順に捨て、残りを古い順に取る。読んだ位置は上限の番号まで進める。
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
    if let maxItems = node.entity.maxItems, remaining.count > maxItems {
      dropped += remaining.prefix(remaining.count - maxItems).map {
        Drop(row: $0, reason: .overflow)
      }
      remaining.removeFirst(remaining.count - maxItems)
    }
    return Read(
      taken: remaining,
      dropped: dropped.filter(\.row.unread).sorted { order($0.row, $1.row) },
      reach: reach(ceilings))
  }

  /// 古さで捨て、判定だけは判断待ちでない覚えている候補のリンクの行を捨てる。残りと捨てた行（古い順）を返す。
  private static func filtered(
    _ rows: [Row], by node: AutomationGraph.Node, _ edges: [AutomationNodeID: AutomationNodeEdge],
    _ context: Context
  ) -> (remaining: [Row], dropped: [Drop]) {
    var remaining: [Row] = []
    var dropped: [Drop] = []
    for row in rows {
      if let hours = edges[row.from]?.maxAgeHours,
        context.now.timeIntervalSince(row.at) > TimeInterval(hours) * 3600
      {
        dropped.append(Drop(row: row, reason: .expired))
      } else if node.role == .judge, let link = row.link, context.closed(link) {
        dropped.append(Drop(row: row, reason: .closed))
      } else {
        remaining.append(row)
      }
    }
    return (remaining, dropped)
  }

  /// 読んだ位置の進め先——つながりと表ごとに上限の番号まで（その間で取らなかった番号は、読む前に無効になった項目・版の追加や
  /// 無効化の番号・期限で消えた出来事）。
  private static func reach(_ ceilings: [Ceiling]) -> [Reach] {
    ceilings.flatMap { ceiling in
      [
        Reach(from: ceiling.from, table: .item, seq: ceiling.seqs.item),
        Reach(from: ceiling.from, table: .event, seq: ceiling.seqs.event),
      ]
    }.filter { $0.seq > 0 }
  }

  /// 古い順（同じ時刻は上流・表・番号の順）。表ごとの番号は時刻と同じ向きに増える。
  static func order(_ a: Row, _ b: Row) -> Bool {
    (a.at, a.from.rawValue, a.table == .item ? 0 : 1, a.seq)
      < (b.at, b.from.rawValue, b.table == .item ? 0 : 1, b.seq)
  }
}

import Foundation

/// 「届いたら」の部品を起こす決まりは 1 つ: 入力のどれかに、その契機の基準線より新しい上流の行があり、走っていなければ起こす。
/// 基準線は、take が new の入力なら表ごとに「読んだ位置」と「前の契機の始まりの時点の上流の最後の番号」の大きい方、take が all
/// の入力なら「前の契機の始まりの時点の上流の変化の番号」（メモリだけ。項目が無効になっても番号は進まないので）。この決まりは、
/// 上流の行が変わったとき（上流の確定）・登録したとき（起動・書き換え・再開。止めた自動化は除く）・その部品の契機が終わったときに
/// 見る。失敗した契機の行は基準線以下なので、この決まりでは起こさない（同じ行で失敗をすぐ繰り返さない）。代わりに、
/// 「届いたら」でない部品の契機が終わるたびに、下流の「届いたら」の部品を、読めば取る行があればすべて起こす（祖先の予定の
/// 間隔でやり直す）。
extension AutomationRunner {
  /// 上流の印: 最後に振った番号（項目・出来事）と変化の番号。
  struct Mark: Equatable {
    var item = 0
    var event = 0
    var changes = 0
  }

  /// 上流の今の印。
  static func mark(of up: AutomationPartID, in automation: Automation) -> Mark {
    let state = automation.parts[up]
    return Mark(
      item: state?.lastItemSeq ?? 0, event: state?.lastEventSeq ?? 0, changes: state?.changes ?? 0)
  }

  /// 入力のどれかに、基準線より新しい上流の行があるか。`previous` は前の契機の始まりの時点の、入力ごとの上流の印。
  static func hasNew(
    _ node: AutomationGraph.Node, in automation: Automation,
    since previous: [AutomationPartID: Mark]
  ) -> Bool {
    let reads = automation.state(node.id).reads
    return node.inputs.contains { edge in
      let up = mark(of: edge.from, in: automation)
      let before = previous[edge.from]
      switch edge.take {
      case .new:
        let read = reads[edge.from] ?? AutomationReadPosition()
        return up.item > max(read.item, before?.item ?? 0)
          || up.event > max(read.event, before?.event ?? 0)
      case .all:
        return up.changes > (before?.changes ?? 0)
      }
    }
  }

  /// 祖先の予定でのやり直しで起こすか。take が new の入力は読んでいない上流の行（読んだ位置より後の番号）があれば、all の
  /// 入力は最後に失敗せずに終えた契機の始まりより後に上流が変わっていれば。`settled` はその契機の始まりの、入力ごとの上流の印
  /// （無ければ変化の番号 0）。失敗した契機の行は読んだ位置が進まないので new では残り、all では基準線が進まないので残る。
  static func needsRetry(
    _ node: AutomationGraph.Node, in automation: Automation,
    settled: [AutomationPartID: Mark]
  ) -> Bool {
    let reads = automation.state(node.id).reads
    return node.inputs.contains { edge in
      let up = mark(of: edge.from, in: automation)
      switch edge.take {
      case .new:
        let read = reads[edge.from] ?? AutomationReadPosition()
        return up.item > read.item || up.event > read.event
      case .all:
        return up.changes > (settled[edge.from]?.changes ?? 0)
      }
    }
  }

  /// 起こす決まり。「届いたら」の部品に、基準線より新しい上流の行があり、走っていなければ起こす。
  func wake(_ id: Int, _ part: AutomationPartID) {
    guard let automation = store.automation(id), let node = automation.graph.node(part),
      node.part.trigger == .arrival
    else { return }
    let key = Self.key(id, part)
    guard Self.hasNew(node, in: automation, since: marks[key] ?? [:]),
      !scheduler.isRunning(id: key)
    else { return }
    scheduler.runNow(id: key)
  }

  /// 失敗のやり直し。「届いたら」でない部品の契機が終わったら、下流の「届いたら」の部品を、最後に失敗せずに終えた契機より後の
  /// 上流の行があればすべて起こす（`AutomationRunner+Wake` の `needsRetry`）。
  func retry(below part: AutomationPartID, in id: Int) {
    guard let automation = store.automation(id) else { return }
    for node in automation.graph.descendants(of: part) where node.part.trigger == .arrival {
      let key = Self.key(id, node.id)
      guard Self.needsRetry(node, in: automation, settled: settled[key] ?? [:]) else { continue }
      scheduler.runNow(id: key)
    }
  }
}

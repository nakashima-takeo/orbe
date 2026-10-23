import Foundation

/// 「届いたら」の部品を起こす決まりは 1 つ: 入力のどれかに、その契機の基準線より新しい上流の行があり、走っていなければ起こす。
/// 基準線は、take が new の入力なら表ごとに「読んだ位置」と「前の契機の始まりの時点の上流の最後の番号」の大きい方、take が all
/// の入力なら「前の契機の始まりの時点の上流の変化の番号」（走らせ役のメモリだけ。項目が無効になっても番号は進まないので）。
/// 読んだ位置と上流の最後の番号は、見るたびに DB から読む。この決まりは、
/// 上流の行が変わったとき（上流の確定）・登録したとき（起動・書き換え・再開。止めた自動化は除く）・その部品の契機が終わったときに
/// 見る。失敗した契機の行は基準線以下なので、この決まりでは起こさない（同じ行で失敗をすぐ繰り返さない）。代わりに、
/// 「届いたら」でない部品の契機が終わるたびに、下流の「届いたら」の部品を、読めば取る行があればすべて起こす（祖先の予定の
/// 間隔でやり直す）。
extension AutomationRunner {
  /// 上流の印: 最後に振った番号（項目・出来事）と変化の番号。
  struct Mark: Equatable {
    var seqs = AutomationSeqs()
    var changes = 0
  }

  /// 受け手の 1 つのつながりの今: 読んだ位置と、上流の今の印。
  struct Inlet: Equatable {
    let read: AutomationSeqs
    let up: Mark
  }

  /// 受け手のつながりごとの今（読んだ位置と上流の最後の番号は DB から、変化の番号はメモリから）。読めなければ nil（ログに
  /// 残す。起こす決まりは起こさない）。
  func inlets(of part: AutomationPartID, in id: Int) -> [AutomationPartID: Inlet]? {
    do throws(AutomationError) {
      let positions = try store.positions(of: part, in: id)
      return Dictionary(
        uniqueKeysWithValues: positions.map { up, position in
          (up, Inlet(read: position.read, up: Mark(seqs: position.last, changes: changes[up] ?? 0)))
        })
    } catch {
      NSLog("[automation] cannot read the inputs of part \(part): \(error)")
      return nil
    }
  }

  /// 入力のどれかに、基準線より新しい上流の行があるか。`previous` は前の契機の始まりの時点の、入力ごとの上流の印。
  static func hasNew(
    _ node: AutomationGraph.Node, _ inlets: [AutomationPartID: Inlet],
    since previous: [AutomationPartID: Mark]
  ) -> Bool {
    node.inputs.contains { edge in
      guard let now = inlets[edge.from] else { return false }
      let before = previous[edge.from]
      switch edge.take {
      case .new:
        return now.up.seqs.item > max(now.read.item, before?.seqs.item ?? 0)
          || now.up.seqs.event > max(now.read.event, before?.seqs.event ?? 0)
      case .all:
        return now.up.changes > (before?.changes ?? 0)
      }
    }
  }

  /// 祖先の予定でのやり直しで起こすか。take が new の入力は読んでいない上流の行（読んだ位置より後の番号）があれば、all の
  /// 入力は最後に失敗せずに終えた契機の始まりより後に上流が変わっていれば。`settled` はその契機の始まりの、入力ごとの上流の印
  /// （無ければ変化の番号 0）。失敗した契機の行は読んだ位置が進まないので new では残り、all では基準線が進まないので残る。
  static func needsRetry(
    _ node: AutomationGraph.Node, _ inlets: [AutomationPartID: Inlet],
    settled: [AutomationPartID: Mark]
  ) -> Bool {
    node.inputs.contains { edge in
      guard let now = inlets[edge.from] else { return false }
      switch edge.take {
      case .new:
        return now.up.seqs.item > now.read.item || now.up.seqs.event > now.read.event
      case .all:
        return now.up.changes > (settled[edge.from]?.changes ?? 0)
      }
    }
  }

  /// 起こす決まり。「届いたら」の部品に、基準線より新しい上流の行があり、走っていなければ起こす。
  func wake(_ id: Int, _ part: AutomationPartID) {
    guard let automation = store.automation(id), let node = automation.graph.node(part),
      node.part.trigger == .arrival
    else { return }
    let key = Self.key(id, part)
    guard !scheduler.isRunning(id: key), let inlets = inlets(of: part, in: id),
      Self.hasNew(node, inlets, since: marks[key] ?? [:])
    else { return }
    scheduler.runNow(id: key)
  }

  /// 失敗のやり直し。「届いたら」でない部品の契機が終わったら、下流の「届いたら」の部品を、最後に失敗せずに終えた契機より後の
  /// 上流の行があればすべて起こす（`AutomationRunner+Wake` の `needsRetry`）。
  func retry(below part: AutomationPartID, in id: Int) {
    guard let automation = store.automation(id) else { return }
    for node in automation.graph.descendants(of: part) where node.part.trigger == .arrival {
      let key = Self.key(id, node.id)
      guard let inlets = inlets(of: node.id, in: id),
        Self.needsRetry(node, inlets, settled: settled[key] ?? [:])
      else { continue }
      scheduler.runNow(id: key)
    }
  }
}

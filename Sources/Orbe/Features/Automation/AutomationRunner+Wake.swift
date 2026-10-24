import Foundation

/// 「届いたら」の部品を起こす決まりは 1 つ: 入力のどれかに、その契機の基準線より新しい上流の番号があり、走っていなければ起こす。
/// 基準線は入力ごと・表ごとに「読んだ位置」と「前の契機の始まりの時点の上流の最後の番号」の大きい方で、取り方によらない——項目の
/// 表の番号は変化の番号（項目の追加・版の追加・無効化で進む）なので、毎回すべてを取る入力も同じ比べ方で上流の変化に起きる。
/// 読んだ位置と上流の最後の番号は、見るたびに DB から読む（再起動の後も、読んでいない変化で起こす）。この決まりは、
/// 上流の行が変わったとき（上流の確定）・登録したとき（起動・書き換え・再開。止めた自動化は除く）・その部品の契機が終わったときに
/// 見る。失敗した契機の行は基準線以下なので、この決まりでは起こさない（同じ行で失敗をすぐ繰り返さない）。代わりに、
/// 「届いたら」でない部品の契機が終わるたびに、下流の「届いたら」の部品を、読んだ位置より後の上流の番号があればすべて起こす
/// （祖先の予定の間隔でやり直す）。
extension AutomationRunner {
  /// 受け手の 1 つのつながりの今: 読んだ位置と、上流の最後の番号。
  struct Inlet: Equatable {
    let read: AutomationSeqs
    let up: AutomationSeqs
  }

  /// 受け手のつながりごとの今（DB から読む）。読めなければ nil（ログに残す。起こす決まりは起こさない）。
  func inlets(of part: AutomationPartID) -> [AutomationPartID: Inlet]? {
    do throws(AutomationError) {
      let positions = try store.positions(of: part)
      return positions.mapValues { Inlet(read: $0.read, up: $0.last) }
    } catch {
      NSLog("[automation] cannot read the inputs of part \(part): \(error)")
      return nil
    }
  }

  /// 入力のどれかに、基準線より新しい上流の番号があるか。`previous` は前の契機の始まりの時点の、入力ごとの上流の最後の番号。
  static func hasNew(
    _ node: AutomationGraph.Node, _ inlets: [AutomationPartID: Inlet],
    since previous: [AutomationPartID: AutomationSeqs]
  ) -> Bool {
    node.inputs.contains { edge in
      guard let now = inlets[edge.from] else { return false }
      let before = previous[edge.from] ?? AutomationSeqs()
      return now.up.item > max(now.read.item, before.item)
        || now.up.event > max(now.read.event, before.event)
    }
  }

  /// 祖先の予定でのやり直しで起こすか: 入力のどれかに、読んだ位置より後の上流の番号があるか（失敗した契機は読んだ位置を
  /// 進めないので、その行と変化が残る）。
  static func needsRetry(_ node: AutomationGraph.Node, _ inlets: [AutomationPartID: Inlet]) -> Bool
  {
    node.inputs.contains { edge in
      guard let now = inlets[edge.from] else { return false }
      return now.up.item > now.read.item || now.up.event > now.read.event
    }
  }

  /// 起こす決まり。「届いたら」の部品に、基準線より新しい上流の行があり、走っていなければ起こす。
  func wake(_ id: Int, _ part: AutomationPartID) {
    guard let automation = store.automation(id), let node = automation.graph.node(part),
      node.part.trigger == .arrival
    else { return }
    let key = Self.key(id, part)
    guard !scheduler.isRunning(id: key), let inlets = inlets(of: part),
      Self.hasNew(node, inlets, since: marks[key] ?? [:])
    else { return }
    scheduler.runNow(id: key)
  }

  /// 失敗のやり直し。「届いたら」でない部品の契機が終わったら、下流の「届いたら」の部品を、読んだ位置より後の上流の番号が
  /// あればすべて起こす（`needsRetry`）。
  func retry(below part: AutomationPartID, in id: Int) {
    guard let automation = store.automation(id) else { return }
    for node in automation.graph.descendants(of: part) where node.part.trigger == .arrival {
      let key = Self.key(id, node.id)
      guard let inlets = inlets(of: node.id), Self.needsRetry(node, inlets) else {
        continue
      }
      scheduler.runNow(id: key)
    }
  }
}

import Foundation

/// 試走の範囲と与えた行の読み。
extension AutomationTrial {
  /// 範囲を解く。知らない部品は `nodeNotFound`、どの行き先にも届かない入口・どの入口からも届かない行き先は `invalid`。
  static func range(of automation: Automation, _ request: Request) throws(AutomationError) -> Range
  {
    let graph = automation.graph
    func checked(_ keys: [String]?, _ name: String) throws(AutomationError)
      -> [AutomationNodeID]?
    {
      guard let keys else { return nil }
      guard !keys.isEmpty else { throw .invalid("\(name) must name at least one node") }
      var ids: [AutomationNodeID] = []
      for key in keys {
        guard let node = graph.node(key: key) else { throw .nodeNotFound(automation.id, key) }
        ids.append(node.id)
      }
      return ids
    }
    func below(_ ids: [AutomationNodeID]) -> Set<AutomationNodeID> {
      Set(ids + ids.flatMap { graph.descendants(of: $0).map(\.id) })
    }
    func above(_ ids: [AutomationNodeID]) -> Set<AutomationNodeID> {
      Set(ids + ids.flatMap { graph.ancestors(of: $0).map(\.id) })
    }
    let from = try checked(request.from, "from")
    let to = try checked(request.to, "to")
    let targets =
      to ?? graph.ends.map(\.id).filter { from.map(below)?.contains($0) ?? true }
    let up = above(targets)
    let entries =
      from ?? graph.nodes.filter { $0.inputs.isEmpty && up.contains($0.id) }.map(\.id)
    let down = below(entries)
    func key(_ id: AutomationNodeID) -> String { graph.node(id)?.key ?? "" }
    for (index, id) in entries.enumerated() where !up.contains(id) {
      throw .invalid("from[\(index)] \"\(key(id))\" reaches no node in to")
    }
    for (index, id) in targets.enumerated() where !down.contains(id) {
      throw .invalid("to[\(index)] \"\(key(id))\" is not reached from any node in from")
    }
    return Range(
      from: unique(entries), to: unique(targets),
      path: graph.nodes.filter { up.contains($0.id) && down.contains($0.id) })
  }

  private static func unique(_ ids: [AutomationNodeID]) -> [AutomationNodeID] {
    var seen = Set<AutomationNodeID>()
    return ids.filter { seen.insert($0).inserted }
  }

  /// 与えた行を、道の根（ちょうど 1 つ）の役割に合わせて読む。取得は取得の読み方でその取得の出力に、入力のある部品は文字列の
  /// `id` を持つ行として受けてその上流の出力にする（上流がちょうど 1 つのときだけ）。判定は断る——判定は出どころ（取得の項目）
  /// から候補を作るので、出どころの無い行は本番では捨てられる。
  static func given(_ rows: [String], in range: Range, of graph: AutomationGraph)
    throws(AutomationError) -> Given
  {
    let roots = range.roots
    guard roots.count == 1, let entry = roots.first else {
      throw .invalid(
        "rows need exactly one entry node (a node with no input in the range); this range has "
          + roots.map { "\"\($0.key)\"" }.joined(separator: ", "))
    }
    switch entry.role {
    case .judge:
      throw .invalid(
        "rows cannot be given to the judge node \"\(entry.key)\": a judge proposes only from items "
          + "a fetch node fetched, so give the items to a fetch node above it")
    case .fetch:
      var outputs = AutomationOutputs(.fetch(since: nil), writer: entry.id)
      let broken = outputs.put(rows.joined(separator: "\n"))
      guard broken.isEmpty else { throw .invalid("rows: \(broken[0].text)") }
      return Given(entry: entry.id, writer: entry.id, rows: outputs.rows)
    case .process, .report, .work, .sideEffect:
      guard entry.inputs.count == 1, let upstream = entry.inputs.first?.from else {
        let keys = entry.inputs.compactMap { graph.node($0.from)?.key }
        throw .invalid(
          "rows: \"\(entry.key)\" has \(keys.count) inputs (\(keys.map { "\"\($0)\"" }.joined(separator: ", "))); "
            + "rows are given as the output of a single input, so give them to one of those nodes "
            + "(with from) instead")
      }
      var outputs = AutomationOutputs(.process([], reachesJudge: false), writer: upstream)
      let broken = outputs.put(rows.joined(separator: "\n"))
      guard broken.isEmpty else { throw .invalid("rows: \(broken[0].text)") }
      return Given(entry: entry.id, writer: upstream, rows: outputs.rows)
    }
  }
}

import Foundation

/// 試走の範囲と与えた行の読み。どちらも検証を通ったノード（`AutomationGraph.Checked`）の鍵と上流の位置で解く——書く前の定義は
/// 足すノードに ID が無く、ID で引くグラフを組めないため。保存した自動化はグラフを同じ形に組み直して（`AutomationGraph.checked`）、
/// 書く前の定義は確かめの結果のまま、同じ規則で解く。
extension AutomationTrial {
  /// 試走の依頼（範囲・与える行・limit）。
  struct Request: Equatable {
    /// 入口のノード。省けば、行き先とその祖先のうち入力の無いノードすべて。
    var from: [String]?
    /// 行き先のノード。省けば、入口から届く終わりのノードすべて。
    var to: [String]?
    /// 入口に与える行（1 行 1 JSON オブジェクト）。道の根が 1 つのときだけ受ける。
    var rows: [String]?
    /// 道の根の取得の回が新しく足す行の上限。毎回すべてを取る受け手は、以前からあり今も有効な行もあわせて読む。
    var limit: Int?
  }

  /// 範囲を解く形: 定義の順の検証を通ったノードと、鍵を引く保存した自動化（書く前の定義には無い）。
  struct Shape {
    let nodes: [AutomationGraph.Checked]
    let savedAutomationId: Int?
  }

  /// 外の形の範囲（入口・行き先・道のノードの鍵）。
  struct Keys {
    let from: [String]
    let to: [String]
    let path: [String]
  }

  /// 写しの上の自動化で解いた範囲。
  struct Range {
    /// 範囲を解いた写しの上の自動化（新しい定義では写しの中だけの ID）。
    let automationId: Int
    let to: [AutomationNodeID]
    /// 道——入口のどれかの子孫か入口そのもので、行き先のどれかの祖先か行き先そのもののノード（定義の順）。
    let path: [AutomationGraph.Node]

    /// 道の根（道の上の入力を持たないノード）。
    var roots: [AutomationGraph.Node] {
      let ids = Set(path.map(\.id))
      return path.filter { ids.isDisjoint(with: $0.inputNodeIds) }
    }
  }

  /// 与えた行: 入口と書くノード（取得の入口ならその取得、入力のある入口ならただ 1 つの上流）の定義の順の位置と、その出力にする行。
  struct Given {
    let entry: Int
    let writer: Int
    let rows: [AutomationNodeRow]

    /// 取得の入口に与えたか（その取得は動かない）。
    var fetched: Bool { writer == entry }
  }

  /// 位置で解いた範囲。
  struct Span {
    let from: [Int]
    let to: [Int]
    /// 道（定義の順）。
    let path: [Int]
  }

  /// 範囲を解く。知らない鍵は、保存した自動化で引くならそのノードが無い（`nodeNotFound`）、書く前の定義なら定義の中の参照の誤り
  /// （`invalid`）。どの行き先にも届かない入口・どの入口からも届かない行き先は `invalid`。
  static func span(of shape: Shape, _ request: Request) throws(AutomationError) -> Span {
    let nodes = shape.nodes
    var downstream = Array(repeating: [Int](), count: nodes.count)
    for (index, node) in nodes.enumerated() {
      for input in node.upstream { downstream[input].append(index) }
    }
    func reach(_ starts: [Int], _ next: (Int) -> [Int]) -> Set<Int> {
      var seen = Set(starts)
      var pending = starts
      while let index = pending.popLast() {
        for neighbor in next(index) where seen.insert(neighbor).inserted {
          pending.append(neighbor)
        }
      }
      return seen
    }
    func below(_ positions: [Int]) -> Set<Int> { reach(positions) { downstream[$0] } }
    func above(_ positions: [Int]) -> Set<Int> { reach(positions) { nodes[$0].upstream } }
    func checked(_ keys: [String]?, _ name: String) throws(AutomationError) -> [Int]? {
      guard let keys else { return nil }
      guard !keys.isEmpty else { throw .invalid("\(name) must name at least one node") }
      var positions: [Int] = []
      for (index, key) in keys.enumerated() {
        guard let position = nodes.firstIndex(where: { $0.key == key }) else {
          guard let automationId = shape.savedAutomationId else {
            throw .invalid("\(name)[\(index)]: unknown node \"\(key)\"")
          }
          throw .nodeNotFound(automationId, key)
        }
        positions.append(position)
      }
      return positions
    }
    let from = try checked(request.from, "from")
    let to = try checked(request.to, "to")
    let reached = from.map(below)
    let targets = to ?? nodes.indices.filter { nodes[$0].ends && reached?.contains($0) ?? true }
    let up = above(targets)
    let entries = from ?? nodes.indices.filter { nodes[$0].upstream.isEmpty && up.contains($0) }
    let down = below(entries)
    for (index, position) in entries.enumerated() where !up.contains(position) {
      throw .invalid("from[\(index)] \"\(nodes[position].key)\" reaches no node in to")
    }
    for (index, position) in targets.enumerated() where !down.contains(position) {
      throw .invalid(
        "to[\(index)] \"\(nodes[position].key)\" is not reached from any node in from")
    }
    return Span(
      from: unique(entries), to: unique(targets),
      path: nodes.indices.filter { up.contains($0) && down.contains($0) })
  }

  private static func unique(_ positions: [Int]) -> [Int] {
    var seen = Set<Int>()
    return positions.filter { seen.insert($0).inserted }
  }

  /// 与えた行（1 行以上）を、道の根（ちょうど 1 つ）の役割に合わせて読む。取得は取得の読み方でその取得の出力に、入力のあるノードは文字列の
  /// `id` を持つ行として受けてその上流の出力にする（上流がちょうど 1 つのときだけ）。下流へ渡す id の接頭（書くノードの ID）を
  /// 含めた大きさで確かめるが、書く前の定義の足すノードは ID がまだ無いので仮の 0 で測る（写しに書いた後に、振った ID で読み直す）。
  static func given(_ rows: [String], in span: Span, of shape: Shape) throws(AutomationError)
    -> Given
  {
    guard !rows.isEmpty else { throw .invalid("rows must have at least one row") }
    let path = Set(span.path)
    let roots = span.path.filter { path.isDisjoint(with: shape.nodes[$0].upstream) }
    guard roots.count == 1, let entry = roots.first else {
      throw .invalid(
        "rows need exactly one entry node (a node with no input in the range); this range has "
          + roots.map { "\"\(shape.nodes[$0].key)\"" }.joined(separator: ", "))
    }
    let node = shape.nodes[entry]
    func read(as input: AutomationNodePass.Input, writer: Int) throws(AutomationError) -> Given {
      var outputs = AutomationOutputs(
        input, writer: shape.nodes[writer].definitionNode.id ?? AutomationNodeID(0))
      let broken = outputs.put(rows.joined(separator: "\n"))
      guard broken.isEmpty else { throw .invalid("rows: \(broken[0].text)") }
      return Given(entry: entry, writer: writer, rows: outputs.rows)
    }
    switch node.role {
    case .fetch:
      return try read(as: .fetch(since: nil, reachesJudge: false), writer: entry)
    case .process, .judge, .report, .work, .sideEffect:
      guard node.upstream.count == 1, let upstream = node.upstream.first else {
        let keys = node.upstream.map { "\"\(shape.nodes[$0].key)\"" }
        throw .invalid(
          "rows: \"\(node.key)\" has \(keys.count) inputs (\(keys.joined(separator: ", "))); "
            + "rows are given as the output of a single input, so give them to one of those nodes "
            + "(with from) instead")
      }
      return try read(as: .process([], reachesJudge: false), writer: upstream)
    }
  }
}

extension AutomationTrial.Keys {
  init(_ span: AutomationTrial.Span, of shape: AutomationTrial.Shape) {
    from = span.from.map { shape.nodes[$0].key }
    to = span.to.map { shape.nodes[$0].key }
    path = span.path.map { shape.nodes[$0].key }
  }
}

extension AutomationGraph.Checked {
  fileprivate var key: String { definitionNode.key }

  /// 終わりのノード（行き先が次のノードでない）。
  fileprivate var ends: Bool { definitionNode.action.destination != .nextNode }
}

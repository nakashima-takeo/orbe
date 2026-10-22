import Foundation

/// 自動化の部品のグラフ。部品（実体）・使う動作の定義・入力のつながり・導いた役割を持ち、作った後は変わらない。組み合わせの
/// 正しさは外の形の定義を `check` に通して確かめてから組む（`AutomationStore` と起動時の読みが通す）。
struct AutomationGraph: Equatable {
  /// 定義の順（部品の位置の順）。
  let nodes: [Node]
  /// 位置ごとの、入力の部品の位置（`from` の中の順）。
  private let upstream: [[Int]]
  /// 位置ごとの、この部品を入力に名指す部品の位置。
  private let downstream: [[Int]]

  /// 部品と、使う動作の定義・入力・導いた役割。
  struct Node: Equatable {
    let part: AutomationPart
    let action: AutomationActionDef
    /// `from` の中の順。
    let inputs: [AutomationPartEdge]
    let role: AutomationPartRole

    var id: AutomationPartID { part.id }
    var key: String { part.key }

    /// 走るモデル。保存は省略のまま持ち、走らせるとき・画面はここで解く。コマンドは nil。
    var model: String? {
      guard case .agent(let agent) = action.method else { return nil }
      return agent.model ?? role.defaultModel
    }

    /// 省略を解いた上限（分）。
    var timeoutMinutes: Int {
      if let minutes = action.timeoutMinutes { return minutes }
      switch action.method {
      case .command: return AutomationActionDef.commandTimeoutMinutes
      case .agent: return AutomationActionDef.agentTimeoutMinutes
      }
    }

    /// 出力の性質を解いたもの。行を出す部品（取得・処理）だけが持ち、処理の省略は出来事の流れ。
    var coverage: AutomationCoverage? {
      switch role {
      case .fetch(let coverage): coverage
      case .process: action.coverage ?? .newArrivals
      case .judge, .report, .work, .sideEffect: nil
      }
    }

    /// 入力の部品。
    var inputParts: [AutomationPartID] { inputs.map(\.from) }
  }

  /// 検証を通った部品の外の形と、導いた役割と、入力の部品の位置。
  struct Checked: Equatable {
    let part: AutomationDefinition.Part
    let role: AutomationPartRole
    let upstream: [Int]
  }

  /// 検証を通った外の形に、部品の実体（ID と使う定義の ID）を当てて組む。`parts` と `checked` は同じ順。
  init(_ checked: [Checked], parts: [AutomationPart]) {
    precondition(checked.count == parts.count, "every checked part has an entity")
    nodes = zip(checked, parts).map { checked, part in
      Node(
        part: part, action: checked.part.action,
        inputs: zip(checked.upstream, checked.part.from).map { index, input in
          AutomationPartEdge(
            from: parts[index].id, take: input.take, maxAgeHours: input.maxAgeHours)
        }, role: checked.role)
    }
    upstream = checked.map(\.upstream)
    var downstream = Array(repeating: [Int](), count: checked.count)
    for (index, inputs) in upstream.enumerated() {
      for input in inputs { downstream[input].append(index) }
    }
    self.downstream = downstream
  }

  /// 外の形に組み直したもの（`from` は鍵で名指し、各部品に ID を添える）。
  var parts: [AutomationDefinition.Part] {
    nodes.map { node in
      AutomationDefinition.Part(
        id: node.id, key: node.key, name: node.part.name, trigger: node.part.trigger,
        from: node.inputs.map { edge in
          AutomationDefinition.Input(
            part: self.node(edge.from)?.key ?? "", take: edge.take, maxAgeHours: edge.maxAgeHours)
        }, action: node.action, maxItems: node.part.maxItems)
    }
  }

  func node(_ id: AutomationPartID) -> Node? {
    nodes.first { $0.id == id }
  }

  /// 今の鍵で引く（外の口の引数は鍵）。
  func node(key: String) -> Node? {
    nodes.first { $0.key == key }
  }

  private func index(_ id: AutomationPartID) -> Int? {
    nodes.firstIndex { $0.id == id }
  }

  /// 入力の深さ順（入力の無い部品が 0、ほかは入力の深さの最大＋1）。同じ深さは定義の順。入力の部品がいつも先に並ぶ。
  var byDepth: [Node] {
    var depths: [Int?] = Array(repeating: nil, count: nodes.count)
    func depth(_ index: Int) -> Int {
      if let known = depths[index] { return known }
      let value = upstream[index].map { depth($0) + 1 }.max() ?? 0
      depths[index] = value
      return value
    }
    let depthOf = nodes.indices.map(depth)
    return nodes.indices.sorted { (depthOf[$0], $0) < (depthOf[$1], $1) }.map { nodes[$0] }
  }

  /// `id` の部品が出した行が、途中で取得の部品を通らずに判定の部品へ届くか（タスク候補へ至るか）。入力を持つツールの agent は
  /// 取得の役割で、届いた行を起こす合図にしか使わないので、行はそこを通り抜けない。
  func reachesTaskCandidates(_ id: AutomationPartID) -> Bool {
    guard let index = index(id) else { return false }
    return !Self.judges(reachedFrom: index, nodes.map(\.role), downstream).isEmpty
  }

  /// `start` の部品が出した行が、途中で取得の部品を通らずに届く判定の部品の位置。
  static func judges(reachedFrom start: Int, _ roles: [AutomationPartRole], _ downstream: [[Int]])
    -> Set<Int>
  {
    var pending = downstream[start]
    var seen = Set<Int>()
    var judges = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted else { continue }
      switch roles[index] {
      case .judge: judges.insert(index)
      case .fetch: continue
      case .process, .report, .work, .sideEffect: pending += downstream[index]
      }
    }
    return judges
  }

  /// `judge` の部品へ、途中で別の取得の部品を通らずに行が届く取得の部品（定義の順）。
  func fetches(reaching judge: AutomationPartID) -> [Node] {
    guard let target = index(judge) else { return [] }
    let roles = nodes.map(\.role)
    return nodes.indices.filter { index in
      nodes[index].role.isFetch
        && Self.judges(reachedFrom: index, roles, downstream).contains(target)
    }.map { nodes[$0] }
  }

  /// `id` の部品を入力に名指す部品（定義の順）。
  func downstream(of id: AutomationPartID) -> [Node] {
    guard let index = index(id) else { return [] }
    return downstream[index].sorted().map { nodes[$0] }
  }

  /// `id` の部品から行が届きうる部品すべて（定義の順）。
  func descendants(of id: AutomationPartID) -> [Node] {
    guard let start = index(id) else { return [] }
    var pending = downstream[start]
    var seen = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted else { continue }
      pending += downstream[index]
    }
    return seen.sorted().map { nodes[$0] }
  }

  /// `id` の部品へ行が届きうる部品すべて（定義の順）。
  func ancestors(of id: AutomationPartID) -> [Node] {
    guard let start = index(id) else { return [] }
    var pending = upstream[start]
    var seen = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted else { continue }
      pending += upstream[index]
    }
    return seen.sorted().map { nodes[$0] }
  }

  /// タスク候補を行き先にする部品（判定。定義の順）。
  var judges: [Node] {
    nodes.filter { $0.role == .judge }
  }

  /// 終わりの部品（行き先が次の部品でない部品。定義の順）。次の部品へ渡す部品は必ず誰かに名指されるので、これらの祖先と
  /// 合わせると全部品になる。
  var ends: [Node] {
    nodes.filter { $0.action.destination != .nextPart }
  }
}

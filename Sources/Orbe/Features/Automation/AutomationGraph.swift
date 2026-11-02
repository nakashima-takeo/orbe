import Foundation

/// 自動化のノードのグラフ。ノード（実体）・使う動作の定義・入力のつながり・導いた役割を持ち、作った後は変わらない。組み合わせの
/// 正しさは外の形の定義を `check` に通して確かめてから組む（`AutomationStore` と起動時の読みが通す）。
struct AutomationGraph: Equatable {
  /// 定義の順（ノードの位置の順）。
  let nodes: [Node]
  /// 自動化の workspace（`Workspace.id`）。自分の workspace を書かないコマンドのノードが継ぐ。
  let workspace: UUID?
  /// 位置ごとの、入力のノードの位置（`from` の中の順）。
  private let upstream: [[Int]]
  /// 位置ごとの、このノードを入力に名指すノードの位置。
  private let downstream: [[Int]]

  /// ノードの実体と、使う動作の定義・入力・導いた役割。
  struct Node: Equatable {
    let entity: AutomationNode
    let action: AutomationActionDef
    /// `from` の中の順。
    let inputs: [AutomationNodeEdge]
    let role: AutomationNodeRole
    /// 走る workspace（コマンドのノードだけ。ノードの workspace か、無ければ自動化の workspace）。
    let workspace: UUID?

    var id: AutomationNodeID { entity.id }
    var key: String { entity.key }

    /// 省略を解いた上限（分）。
    var timeoutMinutes: Int {
      if let minutes = action.timeoutMinutes { return minutes }
      switch action.method {
      case .command: return AutomationActionDef.commandTimeoutMinutes
      case .agent: return AutomationActionDef.agentTimeoutMinutes
      }
    }

    /// 出力の性質を解いたもの（`AutomationNodeRole.coverage`）。
    var coverage: AutomationCoverage? { role.coverage(action.coverage) }

    /// 入力のノード。
    var inputNodeIds: [AutomationNodeID] { inputs.map(\.from) }

    /// 何をするか（省略を解いた動作と入力の集合）。書き換えで何をするかが変わったかはこれで比べる——省略していた値に既定と
    /// 同じ値を書き足しただけでは変わらない。
    var behavior: Behavior {
      var method = action.method
      if case .command(var command) = method {
        command.workspace = workspace
        method = .command(command)
      }
      return Behavior(
        method: method, timeoutMinutes: timeoutMinutes, coverage: coverage,
        destination: action.destination, inputs: Set(inputs))
    }
  }

  /// ノードが何をするか（`Node.behavior`）。
  struct Behavior: Equatable {
    let method: AutomationActionDef.Method
    let timeoutMinutes: Int
    let coverage: AutomationCoverage?
    let destination: AutomationActionDef.Destination
    let inputs: Set<AutomationNodeEdge>
  }

  /// 検証を通ったノードの外の形と、導いた役割・走る workspace と、入力のノードの位置。
  struct Checked: Equatable {
    let definitionNode: AutomationDefinition.Node
    let role: AutomationNodeRole
    let workspace: UUID?
    let upstream: [Int]
  }

  /// 検証を通った外の形に、ノードの実体（ID と使う定義の ID）を当てて組む。`entities` と `checked` は同じ順。`workspace` は検証に
  /// 渡した自動化の workspace。
  init(_ checked: [Checked], entities: [AutomationNode], workspace: UUID?) {
    precondition(checked.count == entities.count, "every checked node has an entity")
    self.workspace = workspace
    nodes = zip(checked, entities).map { checked, entity in
      Node(
        entity: entity, action: checked.definitionNode.action,
        inputs: zip(checked.upstream, checked.definitionNode.from).map { index, input in
          AutomationNodeEdge(
            from: entities[index].id, take: input.take, maxAgeHours: input.maxAgeHours)
        }, role: checked.role, workspace: checked.workspace)
    }
    upstream = checked.map(\.upstream)
    var downstream = Array(repeating: [Int](), count: checked.count)
    for (index, inputs) in upstream.enumerated() {
      for input in inputs { downstream[input].append(index) }
    }
    self.downstream = downstream
  }

  /// 外の形に組み直したもの（`from` は鍵で名指し、各ノードに ID を添える）。
  var definitionNodes: [AutomationDefinition.Node] {
    nodes.map { node in
      AutomationDefinition.Node(
        id: node.id, key: node.key, name: node.entity.name, trigger: node.entity.trigger,
        from: node.inputs.map { edge in
          AutomationDefinition.Input(
            nodeKey: self.node(edge.from)?.key ?? "", take: edge.take, maxAgeHours: edge.maxAgeHours
          )
        }, action: node.action, maxItems: node.entity.maxItems,
        retentionDays: node.entity.retentionDays)
    }
  }

  func node(_ id: AutomationNodeID) -> Node? {
    nodes.first { $0.id == id }
  }

  /// 今の鍵で引く（外の口の引数は鍵）。
  func node(key: String) -> Node? {
    nodes.first { $0.key == key }
  }

  private func index(_ id: AutomationNodeID) -> Int? {
    nodes.firstIndex { $0.id == id }
  }

  /// 入力の深さ順（入力の無いノードが 0、ほかは入力の深さの最大＋1）。同じ深さは定義の順。入力のノードがいつも先に並ぶ。
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

  /// `id` のノードが出した行が、途中で取得のノードを通らずに判定のノードへ届くか（タスク候補へ至るか）。入力を持つツールの agent は
  /// 取得の役割で、届いた行を起こす合図にしか使わないので、行はそこを通り抜けない。
  func reachesTaskCandidates(_ id: AutomationNodeID) -> Bool {
    guard let start = index(id) else { return false }
    var pending = downstream[start]
    var seen = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted else { continue }
      switch nodes[index].role {
      case .judge: return true
      case .fetch: continue
      case .process, .report, .work, .sideEffect: pending += downstream[index]
      }
    }
    return false
  }

  /// `judge` のノードへ行が届くノード——入力を上流へたどり、取得で止めたもの（取得と処理。定義の順）。
  func feeders(of judge: AutomationNodeID) -> [Node] {
    guard let start = index(judge) else { return [] }
    var pending = upstream[start]
    var seen = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted, nodes[index].role != .fetch else { continue }
      pending += upstream[index]
    }
    return seen.sorted().map { nodes[$0] }
  }

  /// `id` のノードを入力に名指すノード（定義の順）。
  func downstream(of id: AutomationNodeID) -> [Node] {
    guard let index = index(id) else { return [] }
    return downstream[index].sorted().map { nodes[$0] }
  }

  /// `id` のノードから行が届きうるノードすべて（定義の順）。
  func descendants(of id: AutomationNodeID) -> [Node] {
    guard let start = index(id) else { return [] }
    var pending = downstream[start]
    var seen = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted else { continue }
      pending += downstream[index]
    }
    return seen.sorted().map { nodes[$0] }
  }

  /// `id` のノードへ行が届きうるノードすべて（定義の順）。
  func ancestors(of id: AutomationNodeID) -> [Node] {
    guard let start = index(id) else { return [] }
    var pending = upstream[start]
    var seen = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted else { continue }
      pending += upstream[index]
    }
    return seen.sorted().map { nodes[$0] }
  }

  /// タスク候補を行き先にするノード（判定。定義の順）。
  var judges: [Node] {
    nodes.filter { $0.role == .judge }
  }

  /// 終わりのノード（行き先が次のノードでないノード。定義の順）。次のノードへ渡すノードは必ず誰かに名指されるので、これらの祖先と
  /// 合わせると全ノードになる。
  var ends: [Node] {
    nodes.filter { $0.action.destination != .nextNode }
  }
}

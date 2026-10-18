import Foundation

/// 検証を通った部品の集まり。作れた時点で値と組み合わせが正しく、作った後は変わらない。JSON へ書き戻すのは `parts` から。
struct AutomationGraph: Equatable {
  /// 定義の順。
  let nodes: [Node]
  /// 位置ごとの、入力の部品の位置。
  private let upstream: [[Int]]
  /// 位置ごとの、この部品を入力に名指す部品の位置。
  private let downstream: [[Int]]

  /// 検証して作る。最初に見つけた誤り 1 つで断る。順は「自分の欄だけで決まるもの → 鍵の名指し → 名指しの向き → 至るか」。
  init(_ parts: [AutomationPart]) throws(AutomationError) {
    guard !parts.isEmpty else { throw .invalid("parts: at least one part is required") }
    var nodes: [Node] = []
    for (index, part) in parts.enumerated() {
      nodes.append(try Self.checked(part, at: "parts[\(index)]"))
    }
    let upstream = try Self.upstream(of: nodes)
    try Self.checkAcyclic(nodes, upstream)
    var downstream = Array(repeating: [Int](), count: nodes.count)
    for (index, inputs) in upstream.enumerated() {
      for input in inputs { downstream[input].append(index) }
    }
    try Self.checkDestinations(nodes, upstream, downstream)
    try Self.checkCoverage(nodes, downstream)
    self.nodes = nodes
    self.upstream = upstream
    self.downstream = downstream
  }

  /// 部品と、導いた役割。
  struct Node: Equatable {
    let part: AutomationPart
    let role: AutomationPartRole

    var key: String { part.key }

    /// 走るモデル。保存は省略のまま持ち、走らせるとき・画面・比較はここで解く。コマンドは nil。
    var model: String? {
      guard case .agent(let agent) = part.method else { return nil }
      return agent.model ?? role.defaultModel
    }

    /// 省略を解いた上限（分）。
    var timeoutMinutes: Int {
      if let minutes = part.timeoutMinutes { return minutes }
      switch part.method {
      case .command: return AutomationPart.commandTimeoutMinutes
      case .agent: return AutomationPart.agentTimeoutMinutes
      }
    }

    /// 行を依頼文に入れる agent か（入力があり、ツールを持たない）。1 回で取る量の上限はこれにだけ掛かる。
    var putsRowsInPrompt: Bool {
      guard case .agent = part.method else { return false }
      return part.readsRows
    }

    /// 何をするか。名前・予定・取得の性質・溜まりの上限を除き、モデルと上限は解いた値で持つ。
    var work: Work {
      var method = part.method
      if case .agent(var agent) = method {
        agent.model = model
        method = .agent(agent)
      }
      return Work(
        method: method, timeoutMinutes: timeoutMinutes, inputs: Set(part.inputs),
        destination: part.destination)
    }
  }

  struct Work: Equatable {
    let method: AutomationPart.Method
    let timeoutMinutes: Int
    let inputs: Set<String>
    let destination: AutomationPart.Destination
  }

  var parts: [AutomationPart] { nodes.map(\.part) }

  func node(_ key: String) -> Node? {
    nodes.first { $0.key == key }
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

  /// `key` の部品が出した行が、途中で取得の部品を通らずに判定の部品へ届くか（タスク候補へ至るか）。入力を持つツールの agent は
  /// 取得の役割で、届いた行を起こす合図にしか使わないので、行はそこを通り抜けない。
  func reachesTaskCandidates(_ key: String) -> Bool {
    guard let index = nodes.firstIndex(where: { $0.key == key }) else { return false }
    return Self.reachesJudge(from: index, nodes, downstream)
  }

  static func reachesJudge(from start: Int, _ nodes: [Node], _ downstream: [[Int]]) -> Bool {
    !judges(reachedFrom: start, nodes, downstream).isEmpty
  }

  /// `start` の部品が出した行が、途中で取得の部品を通らずに届く判定の部品の位置。
  private static func judges(reachedFrom start: Int, _ nodes: [Node], _ downstream: [[Int]])
    -> Set<Int>
  {
    var pending = downstream[start]
    var seen = Set<Int>()
    var judges = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted else { continue }
      switch nodes[index].role {
      case .judge: judges.insert(index)
      case .fetch: continue
      case .process, .report, .work, .sideEffect: pending += downstream[index]
      }
    }
    return judges
  }

  /// `judge` の部品へ、途中で別の取得の部品を通らずに行が届く取得の部品（定義の順）。
  func fetches(reaching judge: String) -> [Node] {
    guard let target = nodes.firstIndex(where: { $0.key == judge }) else { return [] }
    return nodes.indices.filter { index in
      if case .fetch = nodes[index].role {
        return Self.judges(reachedFrom: index, nodes, downstream).contains(target)
      }
      return false
    }.map { nodes[$0] }
  }

  /// `key` の部品を入力に名指す部品（定義の順）。
  func downstream(of key: String) -> [Node] {
    guard let index = nodes.firstIndex(where: { $0.key == key }) else { return [] }
    return downstream[index].sorted().map { nodes[$0] }
  }

  /// `key` の部品から行が届きうる部品すべて（定義の順）。
  func descendants(of key: String) -> [Node] {
    guard let start = nodes.firstIndex(where: { $0.key == key }) else { return [] }
    var pending = downstream[start]
    var seen = Set<Int>()
    while let index = pending.popLast() {
      guard seen.insert(index).inserted else { continue }
      pending += downstream[index]
    }
    return seen.sorted().map { nodes[$0] }
  }

  /// 前後の定義に同じ鍵があり、何をするか（`Node.work`）が変わった部品の鍵（後の定義の順）。足した部品・消した部品は入らない。
  static func reworked(from old: AutomationGraph, to new: AutomationGraph) -> [String] {
    let before = Dictionary(uniqueKeysWithValues: old.nodes.map { ($0.key, $0.work) })
    return new.nodes.filter { node in before[node.key].map { $0 != node.work } ?? false }
      .map(\.key)
  }
}

import Foundation

/// 定義の書き込み——作る（定義だけ）と書き換える（自動化・元にした版・定義）。どちらも確かめる（読みだけ）と掛ける（変異の 1 経路）に
/// 分け、掛けるのは確かめた書き込みだけにする。制御の口は書く前に同じ確かめを通し（`set_automation` も試走も同じ断りを返す）、試走は
/// 写しのストアで同じ書き込みを確かめ直して掛ける。書き換えは自動化のノードとつながりの行を直接書き換え、動作の定義の中身が変わった
/// ノードだけノードの定義を足して指し直す。
extension AutomationStore {
  /// 定義の書き込み。
  enum Write {
    /// 新しい自動化を作る。
    case create(AutomationDefinition)
    /// 自動化を書き換える。版は書き換えの元にした版で、無ければ断る。
    case replace(Int, version: Int?, AutomationDefinition)

    /// `id` が nil なら作り、あれば `version` を添えて書き換える。
    init(_ id: Int?, version: Int?, _ definition: AutomationDefinition) {
      self = id.map { .replace($0, version: version, definition) } ?? .create(definition)
    }

    /// 書き換える自動化（作るなら無い）。
    var automationId: Int? {
      if case .replace(let id, _, _) = self { id } else { nil }
    }

    var definition: AutomationDefinition {
      switch self {
      case .create(let definition), .replace(_, _, let definition): definition
      }
    }
  }

  /// 確かめた書き込み。確かめた時点の書き換える前の自動化を持つので、確かめたストアに、確かめた直後に掛ける。
  struct CheckedWrite {
    let write: Write
    /// 1 行に整えた名前。
    let name: String
    /// 検証を通ったノード（定義の順）。
    let nodes: [AutomationGraph.Checked]
    /// 書き換える前の自動化（作るなら無い）。
    fileprivate let current: Current?
  }

  /// 書き込みの結果と、ノードごとの変化（作ったときは全ノードが足したノード）。
  struct Written {
    let automation: Automation
    /// 足したノード。
    let added: [AutomationNodeID]
    /// 何をするか（省略を解いた動作と入力の集合）が変わったノード。決まりを外した印を下ろした。
    let reworked: [AutomationNodeID]
    /// 外したノード。
    let removed: [AutomationNodeID]
  }

  /// 書き換える前の自動化（定義を読めない自動化は持たない）と、その版と外していないノードとその鍵。
  fileprivate struct Current {
    let id: Int
    let version: Int
    let nodeIds: [AutomationNodeID]
    let keys: [AutomationNodeID: String]
    let automation: Automation?
  }

  /// 書き込みを確かめる（何も書かない）。作るなら、ノードは `id` を持たず、定義が検証を通ること。書き換えるなら、自動化があり（定義を
  /// 読めない自動化も書き換えで直せる）、定義が検証を通り、版が今の版と同じで、ノードの `id` が今のノードを指すこと（`checkIds`）。
  func check(_ write: Write) throws(AutomationError) -> CheckedWrite {
    guard available else { throw unavailableError }
    switch write {
    case .create(let definition):
      if let index = definition.nodes.firstIndex(where: { $0.id != nil }) {
        throw .invalid("nodes[\(index)].id: a new automation has no node ids yet")
      }
      let (name, nodes) = try definition.checked()
      return CheckedWrite(write: write, name: name, nodes: nodes, current: nil)
    case .replace(let id, let version, let definition):
      let current: Current
      if let automation = automation(id) {
        current = Current(
          id: id, version: automation.version, nodeIds: automation.graph.nodes.map(\.id),
          keys: Dictionary(uniqueKeysWithValues: automation.graph.nodes.map { ($0.id, $0.key) }),
          automation: automation)
      } else if let broken = unreadable.first(where: { $0.id == id }) {
        current = Current(
          id: id, version: broken.version, nodeIds: broken.nodeIds,
          keys: try read { try $0.nodeKeys(of: id) }, automation: nil)
      } else {
        throw .automationNotFound(id)
      }
      let (name, nodes) = try definition.checked()
      guard let version else {
        throw .invalid("version: pass the version you read with list_automations to rewrite")
      }
      guard version == current.version else {
        throw .versionMismatch(sent: version, current: current.version)
      }
      try Self.checkIds(definition.nodes, of: id, current: current.keys)
      return CheckedWrite(write: write, name: name, nodes: nodes, current: current)
    }
  }

  /// 確かめた書き込みを掛ける。
  func apply(_ checked: CheckedWrite, now: Date) throws(AutomationError) -> Written {
    let at = TaskItem.storedInstant(now)
    guard let current = checked.current else {
      let automation = try insert(checked, at: at)
      return Written(
        automation: automation, added: automation.graph.nodes.map(\.id), reworked: [],
        removed: [])
    }
    return try rewrite(current, checked, at: at)
  }

  func create(_ definition: AutomationDefinition, now: Date) throws(AutomationError) -> Automation {
    try apply(try check(.create(definition)), now: now).automation
  }

  /// 定義を書き換える。`version` は書き換えの元にした版。ノードは `id` で今のノードを指し（無ければ新しいノード）、何も変わらなければ
  /// 何も書かず、版も進めない。定義を読めない自動化を直すときは、残るノードをすべて何をするかが変わったものとして扱う。止めているかは
  /// 変えない。
  func replace(
    _ id: Int, version: Int?, with definition: AutomationDefinition, now: Date
  ) throws(AutomationError) -> Written {
    try apply(try check(.replace(id, version: version, definition)), now: now)
  }

  private func insert(_ checked: CheckedWrite, at: Date) throws(AutomationError) -> Automation {
    let definition = checked.write.definition
    return try commit(sweepingAt: at) { db, memory in
      let id = try db.insertAutomation(
        name: checked.name, notify: definition.notify, workspace: definition.workspace,
        createdAt: at)
      var entities: [AutomationNode] = []
      for (position, item) in checked.nodes.enumerated() {
        let defId = try db.insert(action: item.definitionNode.action)
        let nodeId = try db.insertNode(
          of: id, at: position, item.definitionNode, defId: defId, addedAt: at)
        entities.append(AutomationNode(item.definitionNode, id: nodeId, defId: defId))
      }
      let graph = AutomationGraph(
        checked.nodes, entities: entities, workspace: definition.workspace)
      for node in graph.nodes { try db.setEdges(of: id, to: node.id, node.inputs) }
      let automation = Automation(
        id: id, name: checked.name, notify: definition.notify, graph: graph, pausedAt: nil,
        version: 1, createdAt: at,
        states: Dictionary(
          uniqueKeysWithValues: try graph.nodes.map { ($0.id, try db.state(of: $0.id)) }))
      memory.automations.append(automation)
      try memory.recount(automation.id, db, now: at)
      return memory.automations[memory.automations.count - 1]
    }
  }

  private func rewrite(_ current: Current, _ checked: CheckedWrite, at: Date)
    throws(AutomationError) -> Written
  {
    let (id, name, definition) = (current.id, checked.name, checked.write.definition)
    return try commit(sweepingAt: at) { db, memory in
      var entities = try Self.entities(checked.nodes, old: current.automation, db)
      if let old = current.automation, old.name == name, old.notify == definition.notify,
        old.graph.workspace == definition.workspace, old.graph.nodes.map(\.entity) == entities,
        old.graph.definitionNodes.map(\.from) == checked.nodes.map(\.definitionNode.from)
      {
        return Written(automation: old, added: [], reworked: [], removed: [])
      }
      let removed = current.nodeIds.filter {
        !Set(checked.nodes.compactMap(\.definitionNode.id)).contains($0)
      }
      var invalidated: [Int] = []
      for nodeId in removed {
        invalidated += try db.removeNode(nodeId, at: at)
      }
      try Self.writeNodes(checked.nodes, &entities, of: id, db, at: at)
      let graph = AutomationGraph(
        checked.nodes, entities: entities, workspace: definition.workspace)
      let rewired = try Self.rewire(graph, of: id, current, db, at: at)
      try db.updateAutomation(
        id, name: name, notify: definition.notify, workspace: definition.workspace,
        version: current.version + 1)
      let row = try db.automationRow(id)
      let automation = Automation(
        id: id, name: name, notify: definition.notify, graph: graph, pausedAt: row.pausedAt,
        version: current.version + 1, createdAt: row.createdAt, states: rewired.states)
      memory.unreadable.removeAll { $0.id == id }
      memory.automations.removeAll { $0.id == id }
      memory.automations.append(automation)
      memory.automations.sort { $0.id < $1.id }
      try memory.withdraw(after: invalidated + rewired.invalidated, db, now: at)
      try memory.withdraw(reviewing: rewired.reviewed, db, now: at)
      try memory.forgetUnheld(db, now: at)
      try memory.recount(id, db, now: at)
      return Written(
        automation: memory.automation(id) ?? automation,
        added: checked.nodes.indices.filter { checked.nodes[$0].definitionNode.id == nil }
          .map { entities[$0].id }, reworked: rewired.reworked, removed: removed)
    }
  }

  /// ノードの行を書き換える: 残るノードを書き換え、`id` の無いノードを足す（`entities` に振った ID を書く）。
  private static func writeNodes(
    _ checked: [AutomationGraph.Checked], _ entities: inout [AutomationNode], of id: Int,
    _ db: AutomationDatabase, at: Date
  ) throws {
    try db.setAsidePlaces(of: id)
    for (position, item) in checked.enumerated() {
      let defId = entities[position].defId
      if let nodeId = item.definitionNode.id {
        try db.updateNode(nodeId, at: position, item.definitionNode, defId: defId)
      } else {
        entities[position] = AutomationNode(
          item.definitionNode,
          id: try db.insertNode(
            of: id, at: position, item.definitionNode, defId: defId, addedAt: at),
          defId: defId)
      }
    }
  }

  /// ノードごとの使う動作の定義。今使っている定義と中身が同じならそのまま指し、違えば足す。新しいノードの ID は仮の 0。
  private static func entities(
    _ checked: [AutomationGraph.Checked], old: Automation?, _ db: AutomationDatabase
  ) throws -> [AutomationNode] {
    try checked.map { item in
      let previous = item.definitionNode.id.flatMap { old?.graph.node($0) }
      let same = previous.flatMap {
        $0.action == item.definitionNode.action ? $0.entity.defId : nil
      }
      let defId = try same ?? db.insert(action: item.definitionNode.action)
      return AutomationNode(
        item.definitionNode, id: item.definitionNode.id ?? AutomationNodeID(0), defId: defId)
    }
  }

  /// つながりの書き換えの結果。
  private struct Rewired {
    var states: [AutomationNodeID: AutomationNodeState] = [:]
    var reworked: [AutomationNodeID] = []
    var invalidated: [Int] = []
    /// 判断待ちの候補を下げる決まりを当て直す判定（何をするかが変わった判定）。
    var reviewed: [AutomationNodeID] = []
  }

  /// つながりを書き換え、出力の性質が変わったノードの今有効な項目を無効にし、何をするかが変わったノードの外した印を下ろし、ノードの
  /// 状態を読み直す。同じノードどうしのつながりが残れば読んだ位置も残る。定義を読めない自動化を直すときは前の性質を知らないので、
  /// 残るノードのうち今の集合でないノードの今有効な項目を無効にし、残るノードをすべて何をするかが変わったものとして扱う。何をするかが
  /// 変わった判定（入力を変えた判定を含む）には、下げる決まりを当て直す（入力を外すと、下げない歯止めだったリンクが抜けうるため）。
  private static func rewire(
    _ graph: AutomationGraph, of id: Int, _ current: Current, _ db: AutomationDatabase, at: Date
  ) throws -> Rewired {
    var rewired = Rewired()
    let old = current.automation
    for node in graph.nodes {
      try db.setEdges(of: id, to: node.id, node.inputs)
      let before = old?.graph.node(node.id)
      let kept = current.nodeIds.contains(node.id)
      let coverageChanged =
        old == nil
        ? kept && node.coverage != .currentSet
        : before?.coverage.map { $0 != node.coverage } ?? false
      if coverageChanged {
        rewired.invalidated += try db.invalidateItems(of: node.id, at: at)
      }
      let reworked = old == nil ? kept : before.map { $0.behavior != node.behavior } ?? false
      if reworked {
        if node.role == .judge { rewired.reviewed.append(node.id) }
        rewired.reworked.append(node.id)
        try db.setBreach(node.id, run: nil)
      }
      rewired.states[node.id] = try db.state(of: node.id)
    }
    return rewired
  }

  /// ノードの `id` を確かめる: この自動化の今のノードだけ・重なりなし・`id` の無いノードの鍵が外れるノードの鍵と同じでない。
  /// `current` は今のノードの台帳（ID と鍵）。
  private static func checkIds(
    _ definitionNodes: [AutomationDefinition.Node], of automation: Int,
    current: [AutomationNodeID: String]
  ) throws(AutomationError) {
    var seen = Set<AutomationNodeID>()
    for (index, definitionNode) in definitionNodes.enumerated() {
      guard let nodeId = definitionNode.id else { continue }
      guard current[nodeId] != nil else {
        throw .invalid("nodes[\(index)].id: \(nodeId) is not a node of automation \(automation)")
      }
      guard seen.insert(nodeId).inserted else {
        throw .invalid("nodes[\(index)].id: \(nodeId) is named twice")
      }
    }
    for (index, definitionNode) in definitionNodes.enumerated() where definitionNode.id == nil {
      if let owner = current.first(where: { $0.value == definitionNode.key })?.key,
        !seen.contains(owner)
      {
        throw .invalid(
          "nodes[\(index)].id: the key \"\(definitionNode.key)\" belongs to node \(owner); send its id to "
            + "keep the node, or use another key for a new node")
      }
    }
  }
}

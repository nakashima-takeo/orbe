import Foundation

/// 定義の書き換え。自動化の部品とつながりの行を直接書き換え、動作の定義の中身が変わった部品だけ部品の定義を足して指し直す。
extension AutomationStore {
  /// 定義を書き換えたときの、部品ごとの変化。
  struct Replaced {
    let automation: Automation
    /// 何をするか（省略を解いた動作と入力の集合）が変わった部品。決まりを外した印を下ろした。
    let reworked: [AutomationNodeID]
    /// 外した部品。
    let removed: [AutomationNodeID]
  }

  /// 書き換える前の自動化（定義を読めない自動化は持たない）と、その版と外していない部品とその鍵。
  private struct Current {
    let version: Int
    let nodeIds: [AutomationNodeID]
    let keys: [AutomationNodeID: String]
    let automation: Automation?
  }

  /// 定義を書き換える。`version` は書き換えの元にした版で、今の版と違えば断る。部品は `id` で今の部品を指し（無ければ新しい
  /// 部品）、自動化の部品とつながりの行を直接書き換える。動作の定義の中身が変わった部品だけ、使う部品の定義を足して指し
  /// 直す。何も変わらなければ何も書かず、版も進めない。定義を読めない自動化も書き換えで直せる（残る部品はすべて何をするかが
  /// 変わったものとして扱う）。止めているかは変えない。
  func replace(
    _ id: Int, version: Int?, with definition: AutomationDefinition, now: Date
  ) throws(AutomationError) -> Replaced {
    let current: Current
    if let automation = automation(id) {
      current = Current(
        version: automation.version, nodeIds: automation.graph.nodes.map(\.id),
        keys: Dictionary(uniqueKeysWithValues: automation.graph.nodes.map { ($0.id, $0.key) }),
        automation: automation)
    } else if let broken = unreadable.first(where: { $0.id == id }) {
      current = Current(
        version: broken.version, nodeIds: broken.nodeIds,
        keys: try read { try $0.nodeKeys(of: id) },
        automation: nil)
    } else {
      throw .automationNotFound(id)
    }
    let (name, checked) = try definition.checked()
    guard let version else {
      throw .invalid("version: pass the version you read with list_automations to rewrite")
    }
    guard version == current.version else {
      throw .versionMismatch(sent: version, current: current.version)
    }
    try Self.checkIds(definition.parts, of: id, current: current.keys)
    let at = TaskItem.storedInstant(now)
    return try commit(sweepingAt: at) { db, memory in
      var entities = try Self.entities(checked, old: current.automation, db)
      if let old = current.automation, old.name == name, old.notify == definition.notify,
        old.graph.nodes.map(\.entity) == entities,
        old.graph.definitionNodes.map(\.from) == checked.map(\.definitionNode.from)
      {
        return Replaced(automation: old, reworked: [], removed: [])
      }
      let removed = current.nodeIds.filter {
        !Set(checked.compactMap(\.definitionNode.id)).contains($0)
      }
      var invalidated: [Int] = []
      for nodeId in removed {
        invalidated += try db.removeNode(nodeId, at: at)
      }
      try Self.writeNodes(checked, &entities, of: id, db, at: at)
      let graph = AutomationGraph(checked, entities: entities)
      let rewired = try Self.rewire(graph, of: id, current, db, at: at)
      try db.updateAutomation(id, name: name, notify: definition.notify, version: version + 1)
      let row = try db.automationRow(id)
      let automation = Automation(
        id: id, name: name, notify: definition.notify, graph: graph, pausedAt: row.pausedAt,
        version: version + 1, createdAt: row.createdAt, states: rewired.states)
      memory.unreadable.removeAll { $0.id == id }
      memory.automations.removeAll { $0.id == id }
      memory.automations.append(automation)
      memory.automations.sort { $0.id < $1.id }
      try memory.withdraw(originatingIn: invalidated + rewired.invalidated, db)
      try memory.forgetUnheld(db)
      try memory.recount(id, db, now: at)
      return Replaced(
        automation: memory.automation(id) ?? automation, reworked: rewired.reworked,
        removed: removed)
    }
  }

  /// 部品の行を書き換える: 残る部品を書き換え、`id` の無い部品を足す（`entities` に振った ID を書く）。
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

  /// 部品ごとの使う動作の定義。今使っている定義と中身が同じならそのまま指し、違えば足す。新しい部品の ID は仮の 0。
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
  }

  /// つながりを書き換え、出力の性質が変わった部品の今有効な項目を無効にし、何をするかが変わった部品の外した印を下ろし、部品の
  /// 状態を読み直す。同じ部品どうしのつながりが残れば読んだ位置も残る。定義を読めない自動化を直すときは前の性質を知らないので、
  /// 残る部品のうち今の集合でない部品の今有効な項目を無効にし、残る部品をすべて何をするかが変わったものとして扱う。
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
      let reworked = old == nil ? kept : before.map { $0.work != node.work } ?? false
      if reworked {
        rewired.reworked.append(node.id)
        try db.setBreach(node.id, run: nil)
      }
      rewired.states[node.id] = try db.state(of: node.id)
    }
    return rewired
  }

  /// 部品の `id` を確かめる: この自動化の今の部品だけ・重なりなし・`id` の無い部品の鍵が外れる部品の鍵と同じでない。
  /// `current` は今の部品の台帳（ID と鍵）。
  private static func checkIds(
    _ definitionNodes: [AutomationDefinition.Node], of automation: Int,
    current: [AutomationNodeID: String]
  ) throws(AutomationError) {
    var seen = Set<AutomationNodeID>()
    for (index, definitionNode) in definitionNodes.enumerated() {
      guard let id = definitionNode.id else { continue }
      guard current[id] != nil else {
        throw .invalid("parts[\(index)].id: \(id) is not a part of automation \(automation)")
      }
      guard seen.insert(id).inserted else {
        throw .invalid("parts[\(index)].id: \(id) is named twice")
      }
    }
    for (index, definitionNode) in definitionNodes.enumerated() where definitionNode.id == nil {
      if let owner = current.first(where: { $0.value == definitionNode.key })?.key,
        !seen.contains(owner)
      {
        throw .invalid(
          "parts[\(index)].id: the key \"\(definitionNode.key)\" belongs to part \(owner); send its id to "
            + "keep the part, or use another key for a new part")
      }
    }
  }
}

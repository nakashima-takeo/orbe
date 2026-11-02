import Foundation

// グラフの検証。断りの文は定義の中の場所（`nodes[2].from` など。制御 API が読む誤りに付ける場所と同じ書き方）で始まる。

extension AutomationGraph {
  /// 検証して、ノードごとの役割・走る workspace と入力のノードの位置を返す。`workspace` は自動化の workspace。最初に見つけた
  /// 誤り 1 つで断る。順は「自動化の workspace → 自分の欄だけで決まるもの → 鍵の名指し → 名指しの向き → 至るか・取り方」。
  /// ノードの `id` は見ない（書き換えの口が確かめる）。workspace が今あるかも見ない——消した workspace を指す保存した定義を、
  /// 読めない定義にしないため（回の始めに解けなければその回が始まらない）。
  static func check(_ definitionNodes: [AutomationDefinition.Node], workspace: UUID?)
    throws(AutomationError) -> [Checked]
  {
    guard !definitionNodes.isEmpty else { throw .invalid("nodes: at least one node is required") }
    if workspace != nil, !definitionNodes.contains(where: \.inheritsWorkspace) {
      throw .invalid(
        "workspace: no command node runs in it; write it only when a command node without its own "
          + "workspace uses it")
    }
    var checked: [Own] = []
    for (index, definitionNode) in definitionNodes.enumerated() {
      checked.append(
        try Self.checked(definitionNode, at: "nodes[\(index)]", inheriting: workspace))
    }
    let upstream = try Self.upstream(of: checked.map(\.definitionNode))
    try Self.checkAcyclic(checked.map(\.definitionNode), upstream)
    var downstream = Array(repeating: [Int](), count: checked.count)
    for (index, inputs) in upstream.enumerated() {
      for input in inputs { downstream[input].append(index) }
    }
    let roles = checked.map(\.role)
    try Self.checkDestinations(checked.map(\.definitionNode), upstream, downstream)
    try Self.checkTakes(checked.map(\.definitionNode), roles, downstream)
    return checked.indices.map {
      Checked(
        definitionNode: checked[$0].definitionNode, role: checked[$0].role,
        workspace: checked[$0].workspace, upstream: upstream[$0])
    }
  }

  /// 自分の欄（と継ぐ自動化の workspace）だけで決まった、ノードの外の形と役割と走る workspace。
  private struct Own {
    let definitionNode: AutomationDefinition.Node
    let role: AutomationNodeRole
    let workspace: UUID?
  }

  /// 自分の欄（と継ぐ自動化の workspace）だけで決まる規則を見て、役割と走る workspace を導く。名前は 1 行に整えて持つ。
  private static func checked(
    _ definitionNode: AutomationDefinition.Node, at path: String, inheriting workspace: UUID?
  ) throws(AutomationError) -> Own {
    var definitionNode = definitionNode
    try checkKey(definitionNode.key, path)
    definitionNode.name = try line(definitionNode.name, "\(path).name")
    if case .scheduled(let timing) = definitionNode.trigger {
      do throws(BackgroundJobError) {
        try timing.validate()
      } catch {
        throw .invalid("\(path).trigger: \(error.message)")
      }
    }
    let runsIn = try checkMethod(definitionNode.action.method, path, inheriting: workspace)
    if let minutes = definitionNode.action.timeoutMinutes,
      !AutomationActionDef.timeoutRange.contains(minutes)
    {
      throw .invalid(
        "\(path).timeoutMinutes: must be \(AutomationActionDef.timeoutRange.lowerBound) to "
          + "\(AutomationActionDef.timeoutRange.upperBound)")
    }
    try checkInputs(definitionNode, path)
    let role = try role(of: definitionNode, path)
    if role == .process, definitionNode.action.coverage == .currentSet {
      if let index = definitionNode.from.firstIndex(where: { $0.take != .all }) {
        throw .invalid(
          "\(path).from[\(index)]: a currentSet node copies its whole input, so take must be all")
      }
      if definitionNode.maxItems != nil {
        throw .invalid(
          "\(path).maxItems: a currentSet node copies its whole input, so it has no maxItems")
      }
    }
    return Own(definitionNode: definitionNode, role: role, workspace: runsIn)
  }

  /// 入力と、受け手の器（件数の上限・届いたら）。
  private static func checkInputs(_ definitionNode: AutomationDefinition.Node, _ path: String)
    throws(AutomationError)
  {
    var named = Set<String>()
    for (index, input) in definitionNode.from.enumerated() {
      guard named.insert(input.nodeKey).inserted else {
        throw .invalid("\(path).from: \"\(input.nodeKey)\" is named twice")
      }
      if let hours = input.maxAgeHours, hours < 1 {
        throw .invalid("\(path).from[\(index)].maxAgeHours: must be at least 1")
      }
    }
    if let items = definitionNode.maxItems {
      guard !definitionNode.from.isEmpty else {
        throw .invalid("\(path).maxItems: only a node with from takes rows")
      }
      guard items >= 1 else { throw .invalid("\(path).maxItems: must be at least 1") }
    }
    if definitionNode.from.isEmpty, definitionNode.trigger == .arrival {
      throw .invalid(
        "\(path).trigger: a node without from receives no rows, so arrival never runs it")
    }
  }

  /// 鍵の重複と未知の鍵の名指しを断り、ノードごとの入力を位置で返す。
  private static func upstream(of definitionNodes: [AutomationDefinition.Node])
    throws(AutomationError)
    -> [[Int]]
  {
    var positions: [String: Int] = [:]
    for (index, definitionNode) in definitionNodes.enumerated() {
      if let first = positions[definitionNode.key] {
        throw .invalid(
          "nodes[\(index)].key: \"\(definitionNode.key)\" is already used by nodes[\(first)]")
      }
      positions[definitionNode.key] = index
    }
    var upstream: [[Int]] = []
    for (index, definitionNode) in definitionNodes.enumerated() {
      var inputs: [Int] = []
      for input in definitionNode.from {
        guard let position = positions[input.nodeKey] else {
          throw .invalid("nodes[\(index)].from: unknown node \"\(input.nodeKey)\"")
        }
        inputs.append(position)
      }
      upstream.append(inputs)
    }
    return upstream
  }

  /// 定義の順で最初に循環に乗るノードを指し、輪を鍵で示す（`a ← b` は a が b を入力に名指す）。
  private static func checkAcyclic(
    _ definitionNodes: [AutomationDefinition.Node], _ upstream: [[Int]]
  )
    throws(AutomationError)
  {
    for start in definitionNodes.indices {
      var seen = Set<Int>()
      func walk(_ index: Int, _ path: [Int]) -> [Int]? {
        for input in upstream[index] {
          if input == start { return path + [start] }
          if seen.insert(input).inserted, let ring = walk(input, path + [input]) { return ring }
        }
        return nil
      }
      if let ring = walk(start, [start]) {
        throw .invalid(
          "nodes[\(start)].from: cycle \(ring.map { "\"\(definitionNodes[$0].key)\"" }.joined(separator: " ← "))"
        )
      }
    }
  }

  /// 行き先が次のノードなのに誰も名指さない → 行き先が次のノードでないノードを名指す（名指した側を指す）。
  private static func checkDestinations(
    _ definitionNodes: [AutomationDefinition.Node], _ upstream: [[Int]], _ downstream: [[Int]]
  ) throws(AutomationError) {
    for (index, definitionNode) in definitionNodes.enumerated()
    where definitionNode.action.destination == .nextNode && downstream[index].isEmpty {
      throw .invalid(
        "nodes[\(index)].deliver: no node names \"\(definitionNode.key)\" in from; name it in a from, or "
          + "deliver to taskCandidates, report or none")
    }
    for (index, inputs) in upstream.enumerated() {
      for input in inputs {
        guard let delivered = definitionNodes[input].action.destination.wireName else { continue }
        throw .invalid(
          "nodes[\(index)].from: \"\(definitionNodes[input].key)\" delivers to \(delivered), so it passes no "
            + "rows to a node")
      }
    }
  }

  /// 毎回すべてを取るつながりを通る行は判定へ至れない（判定は新しい行から候補を作る）。
  private static func checkTakes(
    _ definitionNodes: [AutomationDefinition.Node], _ roles: [AutomationNodeRole],
    _ downstream: [[Int]]
  ) throws(AutomationError) {
    for (index, definitionNode) in definitionNodes.enumerated() {
      let passes =
        roles[index] == .judge
        || (roles[index] != .fetch && !judges(reachedFrom: index, roles, downstream).isEmpty)
      guard passes, let input = definitionNode.from.firstIndex(where: { $0.take == .all }) else {
        continue
      }
      throw .invalid(
        "nodes[\(index)].from[\(input)]: rows taken with take all reach taskCandidates; take new here"
      )
    }
  }

  /// 役割を導く。タスク候補を行き先にするノードが行を見ない・agent の行き先が副作用だけ・出力の性質の有無を断る。
  private static func role(of definitionNode: AutomationDefinition.Node, _ path: String)
    throws(AutomationError) -> AutomationNodeRole
  {
    let role: AutomationNodeRole
    switch definitionNode.action.destination {
    case .nextNode:
      guard definitionNode.readsRows else {
        guard definitionNode.action.coverage != nil else {
          throw .invalid(
            "\(path).coverage: a node that does not read rows fetches items and needs coverage "
              + "(currentSet or newArrivals)")
        }
        return .fetch
      }
      return .process
    case .taskCandidates:
      guard definitionNode.readsRows else {
        throw .invalid(
          "\(path).deliver: taskCandidates needs a node that reads rows (with from, and no tools)")
      }
      role = .judge
    case .report:
      role = definitionNode.action.hasTools ? .work : .report
    case .sideEffect:
      guard case .command = definitionNode.action.method else {
        throw .invalid("\(path).deliver: only a command can deliver none; an agent delivers report")
      }
      role = .sideEffect
    }
    guard definitionNode.action.coverage == nil else {
      throw .invalid("\(path).coverage: only a node that passes rows on has coverage")
    }
    return role
  }

  private static func checkKey(_ key: String, _ path: String) throws(AutomationError) {
    guard AutomationNode.keyLength.contains(key.unicodeScalars.count),
      key.unicodeScalars.allSatisfy(isNameCharacter)
    else {
      throw .invalid(
        "\(path).key: use \(AutomationNode.keyLength.lowerBound) to "
          + "\(AutomationNode.keyLength.upperBound) letters, digits, _ or -")
    }
  }

  /// 手段の欄を見て、走る workspace（コマンドのノードだけ。ノードの workspace か、無ければ継ぐ自動化の workspace）を返す。
  /// workspace が効くコマンドの作業ディレクトリは root からの相対パスで必ず書き、効かないコマンドは絶対パスか省略——workspace を
  /// 消した後の書き戻しで、相対パスの定義が黙ってホームで走らないため。
  private static func checkMethod(
    _ method: AutomationActionDef.Method, _ path: String, inheriting inherited: UUID?
  ) throws(AutomationError) -> UUID? {
    switch method {
    case .command(let command):
      guard !isBlank(command.script) else { throw .invalid("\(path).command: command is empty") }
      let workspace = command.workspace ?? inherited
      let absolute = command.directory?.hasPrefix("/")
      switch (workspace, absolute) {
      case (.some, nil):
        throw .invalid(
          "\(path).directory: a node that runs in a workspace needs a directory relative to its root "
            + "(\".\" for the root)")
      case (.some, true?):
        throw .invalid("\(path).directory: write the directory relative to the workspace root")
      case (nil, false?):
        throw .invalid(
          "\(path).directory: a relative directory needs a workspace (the node's or the "
            + "automation's)")
      default:
        return workspace
      }
    case .agent(let agent):
      switch AgentCatalog.profile(agent.cli)?.headless {
      case .runs: break
      case .refuses(let reason):
        throw .invalid(
          "\(path).agent: \(agent.cli) cannot run in the background (\(reason.message))")
      case nil: throw .invalid("\(path).agent: agent \(agent.cli) is not supported")
      }
      if let model = agent.model, isBlank(model) { throw .invalid("\(path).model: model is empty") }
      if let tool = agent.tools.first(where: { !isMCPToolName($0) && !isBashRule($0) }) {
        throw .invalid(
          "\(path).tools: \(tool) is neither a full MCP tool name (mcp__<server>__<tool>) nor a Bash "
            + "rule (Bash(<command prefix>:*)); other built-in tools, whole servers and wildcards "
            + "are refused")
      }
      guard !isBlank(agent.instruction) else {
        throw .invalid("\(path).instruction: instruction is empty")
      }
      return nil
    }
  }

  private static func line(_ text: String, _ field: String) throws(AutomationError) -> String {
    do throws(TaskStoreError) {
      return try TaskStore.validTitle(text)
    } catch {
      throw .invalid("\(field): must be a single non-empty line")
    }
  }

  /// MCP のツールの完全名（`mcp__<サーバー>__<ツール>`）か。文字はツール名に使えるもの（英数字・`_`・`-`）だけ——`,` を
  /// 通すと `--allowedTools` で連結されてサーバー単位の許可になり、空白も同じく区切りになる。
  private static func isMCPToolName(_ name: String) -> Bool {
    guard name.hasPrefix("mcp__"), name.unicodeScalars.allSatisfy(isNameCharacter) else {
      return false
    }
    let rest = name.dropFirst("mcp__".count)
    guard let separator = rest.range(of: "__") else { return false }
    return separator.lowerBound > rest.startIndex && separator.upperBound < rest.endIndex
  }

  /// `Bash(<接頭>:*)`。接頭は空白だけでなく、`,`（`--allowedTools` の区切り）・`(`・`)`・`*`（接頭の外の一致を許す）・制御文字を
  /// 含まない。
  private static func isBashRule(_ rule: String) -> Bool {
    guard rule.hasPrefix("Bash("), rule.hasSuffix(":*)") else { return false }
    let prefix = rule.dropFirst("Bash(".count).dropLast(":*)".count)
    guard !prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    return !prefix.unicodeScalars.contains {
      ",()*".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0)
    }
  }

  /// 英数字（ASCII）・`_`・`-`。
  private static func isNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
      || scalar == "_" || scalar == "-"
  }

  private static func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

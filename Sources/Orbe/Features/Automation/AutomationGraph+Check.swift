import Foundation

// グラフの検証。断りの文は定義の中の場所（`parts[2].from` など。制御 API が読む誤りに付ける場所と同じ書き方）で始まる。

extension AutomationGraph {
  /// 検証して、部品ごとの役割と入力の部品の位置を返す。最初に見つけた誤り 1 つで断る。順は「自分の欄だけで決まるもの → 鍵の
  /// 名指し → 名指しの向き → 至るか・取り方」。部品の `id` は見ない（書き換えの口が確かめる）。
  static func check(_ parts: [AutomationDefinition.Node]) throws(AutomationError) -> [Checked] {
    guard !parts.isEmpty else { throw .invalid("parts: at least one part is required") }
    var checked: [(part: AutomationDefinition.Node, role: AutomationNodeRole)] = []
    for (index, part) in parts.enumerated() {
      checked.append(try Self.checked(part, at: "parts[\(index)]"))
    }
    let upstream = try Self.upstream(of: checked.map(\.part))
    try Self.checkAcyclic(checked.map(\.part), upstream)
    var downstream = Array(repeating: [Int](), count: checked.count)
    for (index, inputs) in upstream.enumerated() {
      for input in inputs { downstream[input].append(index) }
    }
    let roles = checked.map(\.role)
    try Self.checkDestinations(checked.map(\.part), upstream, downstream)
    try Self.checkTakes(checked.map(\.part), roles, downstream)
    return checked.indices.map {
      Checked(definitionNode: checked[$0].part, role: checked[$0].role, upstream: upstream[$0])
    }
  }

  /// 自分の欄だけで決まる規則を見て、役割を導く。名前は 1 行に整えて持つ。
  private static func checked(_ part: AutomationDefinition.Node, at path: String)
    throws(AutomationError) -> (part: AutomationDefinition.Node, role: AutomationNodeRole)
  {
    var part = part
    try checkKey(part.key, path)
    part.name = try line(part.name, "\(path).name")
    if case .scheduled(let timing) = part.trigger {
      do throws(BackgroundJobError) {
        try timing.validate()
      } catch {
        throw .invalid("\(path).trigger: \(error.message)")
      }
    }
    try checkMethod(part.action.method, path)
    if let minutes = part.action.timeoutMinutes,
      !AutomationActionDef.timeoutRange.contains(minutes)
    {
      throw .invalid(
        "\(path).timeoutMinutes: must be \(AutomationActionDef.timeoutRange.lowerBound) to "
          + "\(AutomationActionDef.timeoutRange.upperBound)")
    }
    try checkInputs(part, path)
    let role = try role(of: part, path)
    if role == .process, part.action.coverage == .currentSet {
      if let index = part.from.firstIndex(where: { $0.take != .all }) {
        throw .invalid(
          "\(path).from[\(index)]: a currentSet part copies its whole input, so take must be all")
      }
      if part.maxItems != nil {
        throw .invalid(
          "\(path).maxItems: a currentSet part copies its whole input, so it has no maxItems")
      }
    }
    return (part, role)
  }

  /// 入力と、受け手の器（件数の上限・届いたら）。
  private static func checkInputs(_ part: AutomationDefinition.Node, _ path: String)
    throws(AutomationError)
  {
    var named = Set<String>()
    for (index, input) in part.from.enumerated() {
      guard named.insert(input.part).inserted else {
        throw .invalid("\(path).from: \"\(input.part)\" is named twice")
      }
      if let hours = input.maxAgeHours, hours < 1 {
        throw .invalid("\(path).from[\(index)].maxAgeHours: must be at least 1")
      }
    }
    if let items = part.maxItems {
      guard !part.from.isEmpty else {
        throw .invalid("\(path).maxItems: only a part with from takes rows")
      }
      guard items >= 1 else { throw .invalid("\(path).maxItems: must be at least 1") }
    }
    if part.from.isEmpty, part.trigger == .arrival {
      throw .invalid(
        "\(path).trigger: a part without from receives no rows, so arrival never runs it")
    }
  }

  /// 鍵の重複と未知の鍵の名指しを断り、部品ごとの入力を位置で返す。
  private static func upstream(of parts: [AutomationDefinition.Node]) throws(AutomationError)
    -> [[Int]]
  {
    var positions: [String: Int] = [:]
    for (index, part) in parts.enumerated() {
      if let first = positions[part.key] {
        throw .invalid("parts[\(index)].key: \"\(part.key)\" is already used by parts[\(first)]")
      }
      positions[part.key] = index
    }
    var upstream: [[Int]] = []
    for (index, part) in parts.enumerated() {
      var inputs: [Int] = []
      for input in part.from {
        guard let position = positions[input.part] else {
          throw .invalid("parts[\(index)].from: unknown part \"\(input.part)\"")
        }
        inputs.append(position)
      }
      upstream.append(inputs)
    }
    return upstream
  }

  /// 定義の順で最初に循環に乗る部品を指し、輪を鍵で示す（`a ← b` は a が b を入力に名指す）。
  private static func checkAcyclic(_ parts: [AutomationDefinition.Node], _ upstream: [[Int]])
    throws(AutomationError)
  {
    for start in parts.indices {
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
          "parts[\(start)].from: cycle \(ring.map { "\"\(parts[$0].key)\"" }.joined(separator: " ← "))"
        )
      }
    }
  }

  /// 行き先が次の部品なのに誰も名指さない → 行き先が次の部品でない部品を名指す（名指した側を指す）。
  private static func checkDestinations(
    _ parts: [AutomationDefinition.Node], _ upstream: [[Int]], _ downstream: [[Int]]
  ) throws(AutomationError) {
    for (index, part) in parts.enumerated()
    where part.action.destination == .nextPart && downstream[index].isEmpty {
      throw .invalid(
        "parts[\(index)].deliver: no part names \"\(part.key)\" in from; name it in a from, or "
          + "deliver to taskCandidates, report or none")
    }
    for (index, inputs) in upstream.enumerated() {
      for input in inputs {
        guard let delivered = parts[input].action.destination.wireName else { continue }
        throw .invalid(
          "parts[\(index)].from: \"\(parts[input].key)\" delivers to \(delivered), so it passes no "
            + "rows to a part")
      }
    }
  }

  /// 毎回すべてを取るつながりを通る行は判定へ至れない（判定は新しい行から候補を作る）。
  private static func checkTakes(
    _ parts: [AutomationDefinition.Node], _ roles: [AutomationNodeRole], _ downstream: [[Int]]
  ) throws(AutomationError) {
    for (index, part) in parts.enumerated() {
      let passes =
        roles[index] == .judge
        || (roles[index] != .fetch && !judges(reachedFrom: index, roles, downstream).isEmpty)
      guard passes, let input = part.from.firstIndex(where: { $0.take == .all }) else { continue }
      throw .invalid(
        "parts[\(index)].from[\(input)]: rows taken with take all reach taskCandidates; take new here"
      )
    }
  }

  /// 役割を導く。タスク候補を行き先にする部品が行を見ない・agent の行き先が副作用だけ・出力の性質の有無を断る。
  private static func role(of part: AutomationDefinition.Node, _ path: String)
    throws(AutomationError) -> AutomationNodeRole
  {
    let role: AutomationNodeRole
    switch part.action.destination {
    case .nextPart:
      guard part.readsRows else {
        guard part.action.coverage != nil else {
          throw .invalid(
            "\(path).coverage: a part that does not read rows fetches items and needs coverage "
              + "(currentSet or newArrivals)")
        }
        return .fetch
      }
      return .process
    case .taskCandidates:
      guard part.readsRows else {
        throw .invalid(
          "\(path).deliver: taskCandidates needs a part that reads rows (with from, and no tools)")
      }
      role = .judge
    case .report:
      role = part.action.hasTools ? .work : .report
    case .sideEffect:
      guard case .command = part.action.method else {
        throw .invalid("\(path).deliver: only a command can deliver none; an agent delivers report")
      }
      role = .sideEffect
    }
    guard part.action.coverage == nil else {
      throw .invalid("\(path).coverage: only a part that passes rows on has coverage")
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

  private static func checkMethod(_ method: AutomationActionDef.Method, _ path: String)
    throws(AutomationError)
  {
    switch method {
    case .command(let command):
      do throws(BackgroundJobError) {
        try BackgroundJob.command(command).validate()
      } catch {
        let field = error == .relativeDirectory ? "directory" : "command"
        throw .invalid("\(path).\(field): \(error.message)")
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

import Foundation

// グラフの検証。断りの文は定義の中の場所（`parts[2].from` など。制御 API が読む誤りに付ける場所と同じ書き方）で始まる。

extension AutomationGraph {
  /// 自分の欄だけで決まる規則を見て、役割を導く。名前は 1 行に整えて持つ。
  static func checked(_ part: AutomationPart, at path: String) throws(AutomationError) -> Node {
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
    try checkMethod(part.method, path)
    if let minutes = part.timeoutMinutes, !AutomationPart.timeoutRange.contains(minutes) {
      throw .invalid(
        "\(path).timeoutMinutes: must be \(AutomationPart.timeoutRange.lowerBound) to "
          + "\(AutomationPart.timeoutRange.upperBound)")
    }
    var named = Set<String>()
    if let twice = part.inputs.first(where: { !named.insert($0).inserted }) {
      throw .invalid("\(path).from: \"\(twice)\" is named twice")
    }
    try checkInboxLimit(part, path)
    if part.inputs.isEmpty, part.trigger == .arrival {
      throw .invalid(
        "\(path).trigger: a part without from receives no rows, so arrival never runs it")
    }
    return Node(part: part, role: try role(of: part, path))
  }

  /// 鍵の重複と未知の鍵の名指しを断り、部品ごとの入力を位置で返す。
  static func upstream(of nodes: [Node]) throws(AutomationError) -> [[Int]] {
    var positions: [String: Int] = [:]
    for (index, node) in nodes.enumerated() {
      if let first = positions[node.key] {
        throw .invalid("parts[\(index)].key: \"\(node.key)\" is already used by parts[\(first)]")
      }
      positions[node.key] = index
    }
    var upstream: [[Int]] = []
    for (index, node) in nodes.enumerated() {
      var inputs: [Int] = []
      for key in node.part.inputs {
        guard let input = positions[key] else {
          throw .invalid("parts[\(index)].from: unknown part \"\(key)\"")
        }
        inputs.append(input)
      }
      upstream.append(inputs)
    }
    return upstream
  }

  /// 定義の順で最初に循環に乗る部品を指し、輪を鍵で示す（`a ← b` は a が b を入力に名指す）。
  static func checkAcyclic(_ nodes: [Node], _ upstream: [[Int]]) throws(AutomationError) {
    for start in nodes.indices {
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
          "parts[\(start)].from: cycle \(ring.map { "\"\(nodes[$0].key)\"" }.joined(separator: " ← "))"
        )
      }
    }
  }

  /// 行き先が次の部品なのに誰も名指さない → 行き先が次の部品でない部品を名指す（名指した側を指す）。
  static func checkDestinations(_ nodes: [Node], _ upstream: [[Int]], _ downstream: [[Int]])
    throws(AutomationError)
  {
    for (index, node) in nodes.enumerated()
    where node.part.destination == .nextPart && downstream[index].isEmpty {
      throw .invalid(
        "parts[\(index)].deliver: no part names \"\(node.key)\" in from; name it in a from, or "
          + "deliver to taskCandidates, report or none")
    }
    for (index, inputs) in upstream.enumerated() {
      for input in inputs {
        guard let delivered = nodes[input].part.destination.wireName else { continue }
        throw .invalid(
          "parts[\(index)].from: \"\(nodes[input].key)\" delivers to \(delivered), so it passes no "
            + "rows to a part")
      }
    }
  }

  /// タスク候補へ至る取得の部品は毎回全件にできない（取得から消えたリンクの候補を下げる規則が成り立たない）。
  static func checkCoverage(_ nodes: [Node], _ downstream: [[Int]]) throws(AutomationError) {
    for (index, node) in nodes.enumerated()
    where node.role == .fetch(.everything) && reachesJudge(from: index, nodes, downstream) {
      throw .invalid(
        "parts[\(index)].coverage: rows of this part reach taskCandidates, so the coverage must be "
          + "currentSet or newArrivals")
    }
  }

  /// 役割を導く。タスク候補を行き先にする部品が行を見ない・agent の行き先が副作用だけ・取得の性質の有無を断る。
  private static func role(of part: AutomationPart, _ path: String) throws(AutomationError)
    -> AutomationPartRole
  {
    let role: AutomationPartRole
    switch part.destination {
    case .nextPart:
      guard part.readsRows else {
        guard let coverage = part.coverage else {
          throw .invalid(
            "\(path).coverage: a part that does not read rows fetches items and needs coverage "
              + "(currentSet, newArrivals or everything)")
        }
        return .fetch(coverage)
      }
      role = .process
    case .taskCandidates:
      guard part.readsRows else {
        throw .invalid(
          "\(path).deliver: taskCandidates needs a part that reads rows (with from, and no tools)")
      }
      role = .judge
    case .report:
      role = part.hasTools ? .work : .report
    case .sideEffect:
      guard case .command = part.method else {
        throw .invalid("\(path).deliver: only a command can deliver none; an agent delivers report")
      }
      role = .sideEffect
    }
    guard part.coverage == nil else {
      throw .invalid("\(path).coverage: only a part that fetches items has coverage")
    }
    return role
  }

  private static func checkKey(_ key: String, _ path: String) throws(AutomationError) {
    guard AutomationPart.keyLength.contains(key.unicodeScalars.count),
      key.unicodeScalars.allSatisfy(isNameCharacter)
    else {
      throw .invalid(
        "\(path).key: use \(AutomationPart.keyLength.lowerBound) to "
          + "\(AutomationPart.keyLength.upperBound) letters, digits, _ or -")
    }
  }

  private static func checkMethod(_ method: AutomationPart.Method, _ path: String)
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

  private static func checkInboxLimit(_ part: AutomationPart, _ path: String)
    throws(AutomationError)
  {
    guard let limit = part.inboxLimit else { return }
    guard !part.inputs.isEmpty else {
      throw .invalid("\(path).inboxLimit: only a part with from has an inbox")
    }
    guard limit.maxAgeHours != nil || limit.maxItems != nil else {
      throw .invalid("\(path).inboxLimit: pass maxAgeHours, maxItems or both")
    }
    if let hours = limit.maxAgeHours, hours < 1 {
      throw .invalid("\(path).inboxLimit: maxAgeHours must be at least 1")
    }
    if let items = limit.maxItems, items < 1 {
      throw .invalid("\(path).inboxLimit: maxItems must be at least 1")
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

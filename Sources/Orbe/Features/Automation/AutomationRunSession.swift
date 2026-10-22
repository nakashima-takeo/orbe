import Foundation

/// 裏で動く agent の 1 回が、Orbe の MCP の道具で自分の回の入力を読み、結果を出す相手。main で使う。
///
/// 道具は役割ごとに決まる。呼ばれるたびにその場で確かめて返事を返し、外れていれば理由を返す——agent は同じ会話の中で直せる。
/// 結果を出す道具は、入力の行を渡し切るまで断る（読まずに答えさせない）。回の終わりに、部品の 1 回が受けたものと申告を取る。
final class AutomationRunSession {
  enum Tool: String, CaseIterable {
    case readRunRows = "read_run_rows"
    case readWaitingProposals = "read_waiting_proposals"
    case readWorkspaces = "read_workspaces"
    case putItems = "put_items"
    case putRows = "put_rows"
    case propose
    case resolve
    case putReport = "put_report"
    case reportNothing = "report_nothing"
    case reportError = "report_error"
  }

  /// 道具の返事。`texts` は返事の中身の塊。
  struct Reply: Equatable {
    let texts: [String]
    let isError: Bool

    static func ok(_ texts: String...) -> Reply { Reply(texts: texts, isError: false) }
    static func refused(_ text: String) -> Reply { Reply(texts: [text], isError: true) }
  }

  /// 1 回の読みで返す行の数の既定と上限、大きさの和の目安（バイト）。claude は MCP の結果を 25,000 トークンで切るので、
  /// 1 ページをそれより小さく収める（先頭の 1 行だけで超えるならその 1 行）。
  static let pageDefault = 50
  static let pageLimit = 100
  static let pageBytes = 48 << 10

  let tools: [Tool]
  private let rows: [String]
  private let choices: AutomationJudgeChoices?
  private var served = IndexSet()
  private(set) var outputs: AutomationOutputs
  /// 何も無い回の申告（理由）。
  private(set) var nothing: String?
  /// 失敗の申告（理由）。
  private(set) var error: String?
  /// 断った結果の呼び出しの、外れた件すべて（呼び出しの形の誤りは位置を持たない 1 件）。
  private(set) var rejected: [AutomationBrokenLine] = []
  /// 最後の結果の呼び出しを断ったか（断られた後に受けた結果の呼び出しが無い）。そのまま終えた回は、断られた中身が黙って
  /// 消えないよう決まりを外した失敗にする。
  private(set) var refusedLast = false

  init(_ input: AutomationPartPass.Input) {
    outputs = AutomationOutputs(input)
    rows = input.rowTexts
    let read: [Tool] = rows.isEmpty ? [] : [.readRunRows]
    switch input {
    case .fetch:
      tools = [.putItems, .reportNothing, .reportError]
      choices = nil
    case .process:
      tools = read + [.putRows, .reportNothing]
      choices = nil
    case .judge(_, let judgeChoices):
      tools = read + [.readWaitingProposals, .readWorkspaces, .propose, .resolve, .reportNothing]
      choices = judgeChoices
    case .report:
      tools = read + [.putReport, .reportNothing]
      choices = nil
    case .work:
      tools = [.putReport, .reportNothing, .reportError]
      choices = nil
    case .sideEffect:
      preconditionFailure("a side effect part is a command")
    }
  }

  /// まだ渡していない入力の行の位置（0 始まり）。
  var unread: [Int] {
    Array(IndexSet(integersIn: 0..<rows.count).subtracting(served))
  }

  /// 結果があるか（受けた結果か、何も無い回の申告）。
  var answered: Bool { outputs.count > 0 || nothing != nil }

  func call(_ name: String, _ arguments: [String: Any]) -> Reply {
    guard let tool = Tool(rawValue: name), tools.contains(tool) else {
      return .refused("\(name) is not a tool of this run")
    }
    switch tool {
    case .readRunRows: return page(arguments)
    case .readWaitingProposals: return .ok(waitingProposals)
    case .readWorkspaces: return .ok(workspaces)
    case .putItems: return put(arguments, "items")
    case .putRows: return put(arguments, "rows")
    case .propose: return put(arguments, "proposals", judging: .proposals)
    case .resolve: return put(arguments, "links") { ["resolve": $0] }
    case .putReport: return putReport(arguments)
    case .reportNothing: return reportNothing(arguments)
    case .reportError: return reportError(arguments)
    }
  }

  // MARK: - 入力

  private func page(_ arguments: [String: Any]) -> Reply {
    guard let offset = arguments["offset"].map(Self.int) ?? 0, offset >= 0 else {
      return .refused("offset must be an integer, 0 or more")
    }
    guard let limit = arguments["limit"].map(Self.int) ?? Self.pageDefault,
      (1...Self.pageLimit).contains(limit)
    else { return .refused("limit must be an integer from 1 to \(Self.pageLimit)") }
    let start = min(offset, rows.count)
    var end = start
    var bytes = 0
    while end < rows.count, end - start < limit {
      bytes += rows[end].utf8.count
      if end > start, bytes > Self.pageBytes { break }
      end += 1
    }
    served.insert(integersIn: start..<end)
    var head: [String: Any] = ["total": rows.count, "offset": start, "count": end - start]
    if end < rows.count { head["next"] = end }
    return .ok(AutomationPrompts.jsonLine(head), rows[start..<end].joined(separator: "\n"))
  }

  private var waitingProposals: String {
    let lines = (choices?.open ?? []).map { proposal in
      var entry: [String: Any] = ["link": proposal.item.link, "title": proposal.title]
      if let due = proposal.due { entry["due"] = due.text }
      return AutomationPrompts.jsonLine(entry)
    }
    return lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
  }

  private var workspaces: String {
    let lines = (choices?.workspaces.listed ?? []).map {
      AutomationPrompts.jsonLine(
        ["workspace": $0.id, "name": $0.name, "root": $0.root] as [String: Any])
    }
    return lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
  }

  // MARK: - 結果

  /// 結果を出す道具が受けられる時点か。断るなら理由。
  private var closed: Reply? {
    if error != nil {
      return .refused("You reported an error; this run has ended without a result.")
    }
    if nothing != nil {
      return .refused("You reported that there is nothing; this run has no result.")
    }
    let unread = unread
    guard unread.isEmpty else {
      return .refused(
        "Read every input item first: the items at offsets \(Self.ranges(unread)) (\(unread.count) "
          + "\(unread.count == 1 ? "item" : "items")) are not read yet; read them with "
          + "\(Tool.readRunRows.rawValue).")
    }
    return nil
  }

  /// `key` の配列の 1 件ずつを 1 行にして確かめる。`line` は 1 件を行にするときの形（既定はそのまま）、`shape` は判定の 1 件の形。
  private func put(
    _ arguments: [String: Any], _ key: String,
    judging shape: AutomationOutputs.JudgeShape = .decisions, _ line: (Any) -> Any = { $0 }
  ) -> Reply {
    if let closed { return closed }
    guard let entries = arguments[key] as? [Any], !entries.isEmpty else {
      return refuse(
        .notNonEmptyArray(key),
        "when there is nothing, call \(Tool.reportNothing.rawValue)")
    }
    let broken = outputs.put(
      entries.map { entry in
        let object = line(entry)
        return JSONSerialization.isValidJSONObject(object)
          ? AutomationPrompts.jsonLine(object) : Self.scalarLine(object)
      }.joined(separator: "\n"), judging: shape)
    guard broken.isEmpty else {
      rejected += broken
      refusedLast = true
      return .refused(
        "Nothing from this call was accepted. Fix these and call again with all of them:\n"
          + broken.map(\.text).joined(separator: "\n"))
    }
    refusedLast = false
    return .ok("Accepted \(entries.count) (\(outputs.count) in all).")
  }

  private func putReport(_ arguments: [String: Any]) -> Reply {
    if let closed { return closed }
    guard let text = arguments["text"] as? String else {
      return refuse(.typeMismatch("text"), "give the report as a string")
    }
    guard outputs.putReport(text) else {
      return refuse(
        .emptyReport, "when there is nothing to report, call \(Tool.reportNothing.rawValue)")
    }
    refusedLast = false
    return .ok("Accepted the report.")
  }

  private func reportNothing(_ arguments: [String: Any]) -> Reply {
    if let closed { return closed }
    guard outputs.count == 0 else {
      return .refused("You already gave results; report_nothing is only for a run with no result.")
    }
    guard rejected.isEmpty else {
      return .refused(
        "Orbe refused results you gave in this run: fix them and give them again, or call "
          + "\(Tool.reportError.rawValue) if you cannot.")
    }
    nothing = (arguments["why"] as? String) ?? ""
    return .ok("Noted: nothing this time.")
  }

  /// 呼び出しの形そのものの誤りで断り、断った結果に数える（位置は持たない）。
  private func refuse(_ fault: AutomationLineFault, _ hint: String) -> Reply {
    let broken = AutomationBrokenLine(line: nil, fault: fault)
    rejected.append(broken)
    refusedLast = true
    return .refused("Nothing from this call was accepted: \(broken.text); \(hint).")
  }

  private func reportError(_ arguments: [String: Any]) -> Reply {
    error = (arguments["what"] as? String) ?? ""
    return .ok("Noted: this run has failed.")
  }

  /// JSON のオブジェクトにならない 1 件（文字列・数など）の 1 行。読みがオブジェクトでないとして外す。
  private static func scalarLine(_ value: Any) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    else { return "null" }
    return String(bytes: data, encoding: .utf8) ?? "null"
  }

  /// 整数（真偽値は整数として受けない。JSONSerialization は true / false も NSNumber に載せる）。
  private static func int(_ raw: Any) -> Int? {
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    return raw as? Int
  }

  /// 昇順の位置を「10-149, 160」の形に。
  private static func ranges(_ numbers: [Int]) -> String {
    var runs: [ClosedRange<Int>] = []
    for number in numbers {
      if let last = runs.last, last.upperBound + 1 == number {
        runs[runs.count - 1] = last.lowerBound...number
      } else {
        runs.append(number...number)
      }
    }
    return runs.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
      .joined(separator: ", ")
  }
}

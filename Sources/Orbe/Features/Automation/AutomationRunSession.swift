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

  /// 1 回の読みで返す行の数の既定と上限、大きさの和の目安（バイト）。agent の `limit` は上限で、Orbe は大きさの和が目安を
  /// 超えたらそこでページを切る（先頭の 1 行は必ず返す。下流へ渡す形の行 1 つは `AutomationOutputs.rowKiB` に収まる）。どのページも claude が
  /// 道具の結果をファイルに書き出す閾値（Orbe の口の `read_run_rows` は 500,000 字に上げてある）より十分小さい。
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
  /// 最後に受けた結果の呼び出しより後に断った呼び出しの、外れた件（断られたまま直っていない件）。
  private var unfixed: [AutomationBrokenLine] = []

  /// 最後の結果の呼び出しを断ったか（断られた後に受けた結果の呼び出しが無い）。そのまま終えた回は、断られた中身が黙って
  /// 消えないよう決まりを外した失敗にする。
  var refusedLast: Bool { !unfixed.isEmpty }

  /// 回の記録に残す外れた件（数は全部、件は断られたままの件を先に、ほかは断った順に）。断らなかった回は nil。
  var rejections: AutomationRejections? {
    guard !rejected.isEmpty else { return nil }
    return AutomationRejections(unfixed + rejected.dropLast(unfixed.count))
  }

  /// `writer` は回を走らせる部品（出す行の下流へ渡す id の接頭）。
  init(_ input: AutomationNodePass.Input, writer: AutomationNodeID) {
    outputs = AutomationOutputs(input, writer: writer)
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

  /// 結果の道具と申告が受けられる時点か。断るなら理由（断った結果には数えない）。
  private var closed: Reply? {
    if error != nil {
      return .refused("You reported an error; this run has ended without a result.")
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
  /// 空の配列は中身の無い呼び出しとして、断った結果に数えずに断る。
  private func put(
    _ arguments: [String: Any], _ key: String,
    judging shape: AutomationOutputs.JudgeShape = .decisions, _ line: (Any) -> Any = { $0 }
  ) -> Reply {
    if let closed { return closed }
    guard let entries = arguments[key] as? [Any] else {
      return refuse(.notArray(key), "give \(key) as an array")
    }
    guard !entries.isEmpty else {
      return .refused(
        "\(key) is empty; when there is nothing, call \(Tool.reportNothing.rawValue).")
    }
    if let afterNothing { return afterNothing }
    let broken = outputs.put(
      entries.map { entry in
        let object = line(entry)
        return JSONSerialization.isValidJSONObject(object)
          ? AutomationPrompts.jsonLine(object) : Self.scalarLine(object)
      }.joined(separator: "\n"), judging: shape)
    guard broken.isEmpty else {
      rejected += broken
      unfixed += broken
      return .refused(
        "Nothing from this call was accepted. Fix these and call again with all of them:\n"
          + broken.map(\.text).joined(separator: "\n"))
    }
    unfixed = []
    return .ok("Accepted \(entries.count) (\(outputs.count) in all).")
  }

  /// 報告の文を受ける。空白だけの文は中身の無い呼び出しとして、断った結果に数えずに断る。
  private func putReport(_ arguments: [String: Any]) -> Reply {
    if let closed { return closed }
    guard let text = arguments["text"] as? String else {
      return refuse(.typeMismatch("text"), "give the report as a string")
    }
    guard AutomationOutputs.kept(text) != nil else {
      return .refused(
        "The report is empty; when there is nothing to report, call "
          + "\(Tool.reportNothing.rawValue).")
    }
    if let afterNothing { return afterNothing }
    outputs.putReport(text)
    unfixed = []
    return .ok("Accepted the report.")
  }

  /// 何も無いと申告した後の結果の呼び出しは、外れた呼び出しとして断る（結果を黙って捨てて、何も無い回として終えない）。
  private var afterNothing: Reply? {
    guard nothing != nil else { return nil }
    return refuse(.afterNothing, "this run reported that there is nothing")
  }

  private func reportNothing(_ arguments: [String: Any]) -> Reply {
    if let closed { return closed }
    guard outputs.count == 0 else {
      return .refused("You already gave results; report_nothing is only for a run with no result.")
    }
    guard rejected.isEmpty else {
      let fallback =
        tools.contains(.reportError)
        ? ", or call \(Tool.reportError.rawValue) if you cannot" : ""
      return .refused(
        "Orbe refused results you gave in this run: fix them and give them again\(fallback).")
    }
    nothing = (arguments["why"] as? String) ?? ""
    return .ok("Noted: nothing this time.")
  }

  /// 呼び出しの形そのものの誤りで断り、断った結果に数える（位置は持たない）。
  private func refuse(_ fault: AutomationLineFault, _ hint: String) -> Reply {
    let broken = AutomationBrokenLine(line: nil, fault: fault)
    rejected.append(broken)
    unfixed.append(broken)
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

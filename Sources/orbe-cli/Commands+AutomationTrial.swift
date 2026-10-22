import Foundation

// `orb automation try` / `trial`（自動化の試走）。usage は `Commands+Automation.swift` の `automationUsage` が持つ。

func automationTry(_ rest: [String]) -> Never {
  var args = rest
  let from = takeOptions(&args, "--from", requires: "a <key> value")
  let to = takeOptions(&args, "--to", requires: "a <key> value")
  let useStdin = takeFlag(&args, "--stdin")
  let limit = takeIntOption(&args, "--limit", requires: "a positive <n>")
  if hasHelp(args) {
    print(automationUsage)
    exit(0)
  }
  rejectLeftovers(args, positionals: 1)
  let id = automationIdArg(args, verb: "try")
  var params: [String: Any] = ["automationId": id]
  if !from.isEmpty { params["from"] = from }
  if !to.isEmpty { params["to"] = to }
  if useStdin { params["rows"] = rows(readStdinText()) }
  if let limit { params["limit"] = limit }
  let result = callOrExit("try_automation", params)
  if wantJSON { printJSON(result) } else { print("started a trial of automation \(id)") }
  exit(0)
}

/// 入口に与える行。1 行 1 JSON オブジェクトで、空行は飛ばす（改行は LF と CRLF）。
private func rows(_ text: String) -> [[String: Any]] {
  var rows: [[String: Any]] = []
  let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
  for (index, line) in lines.enumerated() where !line.allSatisfy(\.isWhitespace) {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    else { usageDie("--stdin line \(index + 1) is not a JSON object") }
    rows.append(object)
  }
  return rows
}

func automationTrial(_ rest: [String]) -> Never {
  var args = rest
  let wait = takeFlag(&args, "--wait")
  let timeoutMs = takeIntOption(&args, "--timeout-ms", requires: "a positive <milliseconds>")
  if hasHelp(args) {
    print(automationUsage)
    exit(0)
  }
  rejectLeftovers(args, positionals: 1)
  let id = automationIdArg(args, verb: "trial")
  var params: [String: Any] = ["automationId": id, "wait": wait]
  if let timeoutMs { params["timeoutMs"] = timeoutMs }
  let result = callOrExit("get_automation_trial", params)
  let d = result as? [String: Any]
  if d?["timedOut"] as? Bool == true { timedOutDie(result) }
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let trial = d?["trial"] as? [String: Any]
  if let failure = trial?["failure"] as? String { print("failed: \(failure)") }
  for part in trial?["parts"] as? [[String: Any]] ?? [] {
    let key = part["key"] as? String ?? "?"
    let cell = (part["runs"] as? [[String: Any]])?.first.map { run in
      for kind in ["held", "given"] {
        if let rows = (run[kind] as? [String: Any])?["rows"] as? [Any] {
          return "\(kind) \(rows.count) rows"
        }
      }
      return runCell(key, run)
    }
    print(
      [key, part["state"].map(display) ?? "-", cell ?? "-"].map(tsvCell).joined(separator: "\t"))
  }
  exit(0)
}

import Foundation

// `orb automation try` / `trial`（自動化の試走）。usage は `Commands+Automation.swift` の `automationUsage` が持つ。

func automationTry(_ rest: [String]) -> Never {
  var args = rest
  let from = takeOptions(&args, "--from", requires: "a <key> value")
  let to = takeOptions(&args, "--to", requires: "a <key> value")
  let rows = takeRowsSource(&args)
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
  if let rows { params["rows"] = readRows(rows) }
  if let limit { params["limit"] = limit }
  let result = callOrExit("try_automation", params)
  if wantJSON { printJSON(result) } else { print("started a trial of automation \(id)") }
  exit(0)
}

/// `--rows <file|->`。`-` は標準入力（`takeOption` は `-` 始まりを値の席に受けないので、`-` だけを先に抜く）。
private func takeRowsSource(_ args: inout [String]) -> String? {
  if let index = args.firstIndex(of: "--rows"), index + 1 < args.count, args[index + 1] == "-" {
    args.removeSubrange(index...(index + 1))
    return "-"
  }
  return takeOption(&args, "--rows", requires: "a <file> or -")
}

/// 1 行 1 JSON オブジェクト（空行は飛ばす）。
private func readRows(_ source: String) -> [[String: Any]] {
  let data: Data
  if source == "-" {
    data = FileHandle.standardInput.readDataToEndOfFile()
  } else {
    guard let read = FileManager.default.contents(atPath: source) else {
      usageDie("cannot read --rows file: \(source)")
    }
    data = read
  }
  guard let text = String(data: data, encoding: .utf8) else { usageDie("--rows is not UTF-8") }
  var rows: [[String: Any]] = []
  for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
  where !line.allSatisfy(\.isWhitespace) {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    else { usageDie("--rows line \(index + 1) is not a JSON object") }
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
    let cell = (part["runs"] as? [[String: Any]])?.last.map { run in
      guard let held = run["held"] as? [String: Any] else { return runCell(key, run) }
      return "held \((held["rows"] as? [Any])?.count ?? 0) rows"
    }
    print(
      [key, part["state"].map(display) ?? "-", cell ?? "-"].map(tsvCell).joined(separator: "\t"))
  }
  exit(0)
}

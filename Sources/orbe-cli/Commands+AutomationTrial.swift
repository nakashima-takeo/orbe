import Foundation

// `orb automation try` / `trial`（自動化の試走）。usage は `Commands+Automation.swift` の `automationUsage` が持つ。

/// 試走を始め、試走の ID を出す。`--definition` は標準入力の定義（`set` と同じ JSON）を書く前の定義として試す——`<id>` が無ければ
/// 新しい定義、あれば `--version` からの書き換え。組めない組み合わせは標準入力を読む前に usage エラー。
func automationTry(_ rest: [String]) -> Never {
  var args = rest
  let from = takeOptions(&args, "--from", requires: "a <key> value")
  let to = takeOptions(&args, "--to", requires: "a <key> value")
  let useDefinition = takeFlag(&args, "--definition")
  let version = takeIntOption(&args, "--version", requires: "a positive <n>")
  let rowsPath = takeOption(&args, "--rows", requires: "a <path> value")
  let limit = takeIntOption(&args, "--limit", requires: "a positive <n>")
  if hasHelp(args) {
    print(automationUsage)
    exit(0)
  }
  rejectLeftovers(args, positionals: 1)
  let id = args.isEmpty ? nil : automationIdArg(args, verb: "try")
  checkTrialTarget(id: id, version: version, definition: useDefinition)
  var params: [String: Any] = [:]
  if let id { params["automationId"] = id }
  if let version { params["version"] = version }
  if useDefinition { params["definition"] = definitionFromStdin(verb: "try") }
  if !from.isEmpty { params["from"] = from }
  if !to.isEmpty { params["to"] = to }
  if let rowsPath { params["rows"] = rows(at: rowsPath) }
  if let limit { params["limit"] = limit }
  let result = callOrExit("try_automation", params)
  if wantJSON {
    printJSON(result)
  } else {
    let trial = (result as? [String: Any])?["trial"] as? [String: Any]
    print(trial?["trialId"] as? Int ?? -1)
  }
  exit(0)
}

/// 試す対象の組み合わせ: 自動化か定義のどちらかが要り、版は自動化を直す定義にだけ添え、自動化を直す定義には版が要る。
private func checkTrialTarget(id: Int?, version: Int?, definition: Bool) {
  if version != nil, id == nil || !definition {
    usageDie("automation try --version requires <id> and --definition (the rewrite to try)")
  }
  if id != nil, definition, version == nil {
    usageDie("automation try <id> --definition requires --version (the version list --json shows)")
  }
  if id == nil, !definition {
    usageDie("automation try requires <id> or --definition")
  }
}

/// 入口に与える行。ファイルの 1 行 1 JSON オブジェクトで、空行は飛ばす（改行は LF と CRLF）。行が 1 つも無いファイルは断る。
private func rows(at path: String) -> [[String: Any]] {
  guard let data = FileManager.default.contents(atPath: path) else {
    usageDie("--rows cannot read \(path)")
  }
  guard let text = String(data: data, encoding: .utf8) else {
    usageDie("--rows \(path) is not valid UTF-8")
  }
  var rows: [[String: Any]] = []
  let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
  for (index, line) in lines.enumerated() where !line.allSatisfy(\.isWhitespace) {
    guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    else { usageDie("--rows line \(index + 1) is not a JSON object") }
    rows.append(object)
  }
  guard !rows.isEmpty else { usageDie("--rows \(path) has no rows") }
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
  guard let raw = args.first else { usageDie("automation trial requires <trialId>") }
  guard let id = Int(raw), id >= 1 else { usageDie("invalid trial id: \(raw)") }
  var params: [String: Any] = ["trialId": id, "wait": wait]
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
  for node in trial?["nodes"] as? [[String: Any]] ?? [] {
    let key = node["key"] as? String ?? "?"
    let runs = node["runs"] as? [[String: Any]] ?? []
    let flowed = runs.first { $0["atWrite"] as? Bool != true }.map { trialCell(key, $0) }
    let written = runs.first { $0["atWrite"] as? Bool == true }.map { trialCell(key, $0) }
    print(
      [key, node["state"].map(display) ?? "-", flowed ?? "-", written ?? "-"].map(tsvCell)
        .joined(separator: "\t"))
  }
  exit(0)
}

/// 試走の回 1 つの表示。止めた副作用・仕事と与えた取得は行の数、ほかは `list` の「前回」と同じ語。
private func trialCell(_ key: String, _ run: [String: Any]) -> String {
  for kind in ["held", "given"] {
    if let rows = (run[kind] as? [String: Any])?["rows"] as? [Any] {
      return "\(kind) \(rows.count) rows"
    }
  }
  return runCell(key, run)
}

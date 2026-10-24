import Foundation

// `orb automation` の回の記録の読み（`list` の前回の列・`runs`）。

/// 最新の部品の回の要約（時刻が同じなら記録の ID の大きい方。アプリの部品の回の並びと揃える）。
func lastRunCell(_ nodes: [String: [String: Any]]) -> String? {
  let latest = nodes.compactMap { key, node in
    (node["lastRun"] as? [String: Any]).map { (key: key, run: $0) }
  }.max {
    ($0.run["startedAt"] as? String ?? "", $0.run["recordId"] as? Int ?? 0)
      < ($1.run["startedAt"] as? String ?? "", $1.run["recordId"] as? Int ?? 0)
  }
  return latest.map { runCell($0.key, $0.run) }
}

/// 部品の回の要約。回の記録だけから組む: `<開始> <鍵> failed: <理由>`、または `<開始> <鍵>: ` に、取得は
/// `12 fetched, 3 new`、処理は `12 in, 4 out`、判定は `2 proposed`、報告は `reported` か `nothing to report`、副作用は
/// `command exited 0`、仕事は `agent exited 0` を続ける。
func runCell(_ key: String, _ run: [String: Any]) -> String {
  let started = run["startedAt"].map(display) ?? "?"
  if run["unknown"] as? Bool == true {
    let outcome = run["failed"] as? Bool == true ? "failed" : "succeeded"
    return "\(started) \(key): unreadable record (\(outcome))"
  }
  if let failure = run["failure"] as? String { return "\(started) \(key) failed: \(failure)" }
  let execution = run["execution"] as? [String: Any]
  let count = execution?["count"].map(display) ?? "0"
  let ending = execution?["ending"].map(display) ?? "?"
  let result = run["result"] as? [String: Any]
  let summary: String
  switch result?["kind"] as? String {
  case "fetch": summary = "\(count) fetched, \(result?["fresh"].map(display) ?? "0") new"
  case "process": summary = "\(run["taken"].map(display) ?? "0") in, \(count) out"
  case "judge": summary = "\(result?["proposed"].map(display) ?? "0") proposed"
  case "report": summary = result?["text"] == nil ? "nothing to report" : "reported"
  case "sideEffect": summary = "command \(ending)"
  case "work": summary = "agent \(ending)"
  default: summary = ending
  }
  return "\(started) \(key): \(summary)"
}

/// 回の記録を新しい順に 1 ページ。1 行 1 回: 記録の ID と回の要約。続きがあれば最後に `next <recordId>`。
func automationRuns(_ rest: [String]) -> Never {
  exitIfAutomationHelp(rest)
  var args = rest
  let nodeKey = takeOption(&args, "--part", requires: "a <key> value")
  let before = takeIntOption(&args, "--before", requires: "a positive <recordId>")
  let limit = takeIntOption(&args, "--limit", requires: "a positive <n>")
  rejectLeftovers(args, positionals: 1)
  var params: [String: Any] = ["automationId": automationIdArg(args, verb: "runs")]
  if let nodeKey { params["partKey"] = nodeKey }
  if let before { params["before"] = before }
  if let limit { params["limit"] = limit }
  let result = callOrExit("list_automation_runs", params)
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let object = result as? [String: Any]
  for run in object?["runs"] as? [[String: Any]] ?? [] {
    print(
      [run["recordId"].map(display) ?? "-", runCell(run["partKey"].map(display) ?? "?", run)]
        .map(tsvCell).joined(separator: "\t"))
  }
  if let next = object?["next"] { print("next\t\(display(next))") }
  exit(0)
}

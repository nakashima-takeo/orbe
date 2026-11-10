import Foundation
import OrbeAutomationReference

// `orb automation <サブコマンド>` の実装と usage。定義は MCP の set_automation の definition と同じ形の JSON を標準入力で
// 受け、検証は control に任せる（ノードはコマンドか agent かで項目が入れ子になるので、フラグに割ると検証が 2 か所に割れる）。

// MARK: - usage

let automationUsageLines = [
  "orb automation list [--json]",
  "orb automation proposals [<id>] [--json]",
  "orb automation set [<id> --version <n>] [--json]   (definition JSON on stdin)",
  "orb automation run <id> [--node <key>] [--json]",
  "orb automation runs <id> [--node <key>] [--before <recordId>] [--limit <n>] [--json]",
  "orb automation try (<id> | [<id> --version <n>] --definition) [--from <key>]... [--to <key>]..."
    + " [--rows <path>] [--limit <n>] [--json]   (with --definition, definition JSON on stdin)",
  "orb automation trial <trialId> [--wait] [--timeout-ms <ms>] [--json]",
  "orb automation pause <id> [--node <key>] [--json]",
  "orb automation resume <id> [--node <key>] [--json]",
  "orb automation rm <id> [--json]",
]

/// usage の行・CLI の注・共有の節（MCP の自動化ツールと同じ文）。
let automationUsage =
  """
  orb automation — automations: graphs of nodes that fetch from outside on their own
  schedules, then process, judge into task candidates, report, do work with tools, or
  run side effects

  USAGE:
  \(usageBlock(automationUsageLines))

  """ + "\n" + automationNotes + "\n\n" + AutomationReference.sections.joined(separator: "\n\n")

/// 共有の節の振る舞いをどのサブコマンド・フラグで呼ぶか。
private let automationNotes = """
  COMMANDS
  The sections after this one describe the JSON that `--json` prints and the behavior behind
  each command.
  - set reads the definition JSON on stdin. Without <id> it creates an automation and prints
  its id; with <id> it replaces the whole definition and needs `--version`, the `version` you
  read. To edit, take `definition` and `version` from list `--json`, change the definition
  and pipe it whole:
      orb automation list --json | jq '.automations[] |
        select(.automationId==3) | .definition' | ... | orb automation set 3 --version 4
  - try starts a trial and prints its trial id. With `--definition` it reads a definition on
  stdin (the same JSON as set) and tries it before it is written: a new automation without
  <id>, or a rewrite of <id> from `--version`. `--from` and `--to` (each repeatable) give the
  entry and target keys, `--rows` a file of rows to give the entry (one JSON object per line;
  blank lines are skipped), and `--limit` the cap on new rows.
  - trial reads a trial by its id, one line per node: key, state, its latest run, and its
  latest run at the moment of writing ("held N rows", "given N rows" or "-"); a trial that
  ended early starts with "failed: <reason>". The rows, proposals and held rows are in
  `--json`. `--wait` waits until the trial ends, up to `--timeout-ms` (default 3600000, max
  86400000), and exits 124 on timeout.
  - run flows to the node `--node` (every end node without it) and returns at once.
  - pause and resume act on the automation, or on the node `--node` only.
  - list prints one automation per line: id, state (active, paused, running or unreadable),
  name, the next schedule ("every 30m" or "cron 0 9 * * 1-5", with " +N" for N more
  scheduled nodes, or "manual"), the next run time, and the latest run of any node:
  "<start> <key>: " and then "12 fetched, 3 new", "12 in, 4 out", "2 proposed", "reported",
  "nothing to report", "command exited 0" or "agent exited 0", or "<start> <key> failed:
  <reason>".
  - runs prints run records newest first, one per line (record id and the same summary), up
  to `--limit` (default 20, max 100) of the node `--node` or of all nodes, then
  "next <recordId>" when more remain; pass that id as `--before` for the next page.
  - proposals prints one proposal per line: id, state, automation id, due, title, link.
  - rm deletes the automation.
  """

// MARK: - サブコマンド

func runAutomation(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": automationList(rest)
  case "proposals": automationProposals(rest)
  case "set": automationSet(rest)
  case "run": automationRun(rest)
  case "runs": automationRuns(rest)
  case "try": automationTry(rest)
  case "trial": automationTrial(rest)
  case "pause": automationPause(rest, paused: true)
  case "resume": automationPause(rest, paused: false)
  case "rm":
    automationSimple(rest, verb: "rm", method: "delete_automation", done: "removed automation")
  case nil:
    print(automationUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(automationUsage)
      exit(0)
    }
    usageDie("unknown automation command: \(other)")
  }
}

func exitIfAutomationHelp(_ args: [String]) {
  guard hasHelp(args) else { return }
  print(automationUsage)
  exit(0)
}

private func automationList(_ rest: [String]) -> Never {
  exitIfAutomationHelp(rest)
  rejectLeftovers(rest, positionals: 0)
  let result = callOrExit("list_automations", [:])
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let automations = (result as? [String: Any])?["automations"] as? [[String: Any]] ?? []
  for automation in automations {
    let nodes = automation["nodes"] as? [String: [String: Any]] ?? [:]
    let state =
      automation["definitionError"] != nil
      ? "unreadable"
      : nodes.values.contains { $0["running"] as? Bool == true }
        ? "running" : automation["paused"] as? Bool == true ? "paused" : "active"
    let definition = automation["definition"] as? [String: Any]
    let next = nodes.compactMap { key, node in
      (node["nextRunAt"] as? String).map { (key: key, at: $0) }
    }.min { $0.at < $1.at }
    print(
      [
        automation["automationId"], state, definition?["name"],
        scheduleCell(definition?["nodes"] as? [[String: Any]] ?? [], next: next?.key),
        next?.at, lastRunCell(nodes),
      ].map { $0.map(display) ?? "-" }.map(tsvCell).joined(separator: "\t"))
  }
  exit(0)
}

/// 次に来るノードの予定（`every 30m` / `cron 0 9 * * 1-5`）。ほかに予定のあるノードがあれば ` +N`、予定のあるノードが無ければ
/// `manual`。
private func scheduleCell(_ nodes: [[String: Any]], next: String?) -> String {
  let scheduled = nodes.compactMap { node -> (key: String, words: String)? in
    guard let trigger = node["trigger"] as? [String: Any], let key = node["key"] as? String else {
      return nil
    }
    switch trigger["kind"] as? String {
    case "interval": return (key, "every \(trigger["minutes"].map(display) ?? "?")m")
    case "cron": return (key, "cron " + ((trigger["expression"] as? String) ?? "?"))
    default: return nil
    }
  }
  guard let first = scheduled.first else { return "manual" }
  let shown = scheduled.first { $0.key == next } ?? first
  return scheduled.count == 1 ? shown.words : "\(shown.words) +\(scheduled.count - 1)"
}

private func automationProposals(_ rest: [String]) -> Never {
  exitIfAutomationHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  var params: [String: Any] = [:]
  if !rest.isEmpty { params["automationId"] = automationIdArg(rest, verb: "proposals") }
  let result = callOrExit("list_automation_proposals", params)
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let proposals = (result as? [String: Any])?["proposals"] as? [[String: Any]] ?? []
  for proposal in proposals {
    print(
      [
        proposal["proposalId"], proposal["state"], proposal["automationId"], proposal["due"],
        proposal["title"], proposal["link"],
      ].map { $0.map(display) ?? "-" }.map(tsvCell).joined(separator: "\t"))
  }
  exit(0)
}

private func automationSet(_ rest: [String]) -> Never {
  exitIfAutomationHelp(rest)
  var args = rest
  let version = takeIntOption(&args, "--version", requires: "a positive <n>")
  rejectLeftovers(args, positionals: 1)
  let id = args.isEmpty ? nil : automationIdArg(args, verb: "set")
  if id != nil, version == nil {
    usageDie("automation set <id> requires --version (the version list --json shows)")
  }
  if id == nil, version != nil {
    usageDie("automation set --version requires the <id> of the automation to rewrite")
  }
  var params: [String: Any] = ["definition": definitionFromStdin(verb: "set")]
  if let id { params["automationId"] = id }
  if let version { params["version"] = version }
  let result = callOrExit("set_automation", params)
  if wantJSON {
    printJSON(result)
  } else if let id {
    print("updated automation \(id)")
  } else {
    let automation = (result as? [String: Any])?["automation"] as? [String: Any]
    print(automation?["automationId"] as? Int ?? -1)
  }
  exit(0)
}

private func automationPause(_ rest: [String], paused: Bool) -> Never {
  exitIfAutomationHelp(rest)
  var args = rest
  let nodeKey = takeOption(&args, "--node", requires: "a <key> value")
  rejectLeftovers(args, positionals: 1)
  let id = automationIdArg(args, verb: paused ? "pause" : "resume")
  var params: [String: Any] = ["automationId": id, "paused": paused]
  if let nodeKey { params["nodeKey"] = nodeKey }
  let result = callOrExit("pause_automation", params)
  if wantJSON {
    printJSON(result)
  } else if let nodeKey {
    print("\(paused ? "paused" : "resumed") node \(nodeKey) of automation \(id)")
  } else {
    print("\(paused ? "paused" : "resumed") automation \(id)")
  }
  exit(0)
}

private func automationRun(_ rest: [String]) -> Never {
  exitIfAutomationHelp(rest)
  var args = rest
  let nodeKey = takeOption(&args, "--node", requires: "a <key> value")
  rejectLeftovers(args, positionals: 1)
  let id = automationIdArg(args, verb: "run")
  var params: [String: Any] = ["automationId": id]
  if let nodeKey { params["nodeKey"] = nodeKey }
  let result = callOrExit("run_automation", params)
  if wantJSON { printJSON(result) } else { print("started automation \(id)") }
  exit(0)
}

private func automationSimple(_ rest: [String], verb: String, method: String, done: String) -> Never
{
  exitIfAutomationHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  let id = automationIdArg(rest, verb: verb)
  let result = callOrExit(method, ["automationId": id])
  if wantJSON { printJSON(result) } else { print("\(done) \(id)") }
  exit(0)
}

/// 標準入力の定義の JSON オブジェクト（`set` と `try --definition`）。空・JSON オブジェクトでないのは usage エラー。
func definitionFromStdin(verb: String) -> [String: Any] {
  let data = FileHandle.standardInput.readDataToEndOfFile()
  guard !data.isEmpty else { usageDie("automation \(verb) reads the definition JSON from stdin") }
  guard let definition = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    usageDie("automation \(verb): stdin is not a JSON object")
  }
  return definition
}

/// 位置引数の automation id（正の整数）。
func automationIdArg(_ args: [String], verb: String) -> Int {
  guard let raw = args.first else { usageDie("automation \(verb) requires <id>") }
  guard let id = Int(raw), id >= 1 else { usageDie("invalid automation id: \(raw)") }
  return id
}

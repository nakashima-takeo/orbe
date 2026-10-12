import Foundation

// `orb automation <サブコマンド>` の実装と usage。定義は MCP の set_automation の definition と同じ形の JSON を標準入力で
// 受け、検証は control に任せる（取得元や段はコマンドか agent かで項目が入れ子になるので、フラグに割ると検証が 2 か所に割れる）。

// MARK: - usage

let automationUsageLines = [
  "orb automation list [--json]",
  "orb automation proposals [<id>] [--json]",
  "orb automation set [<id>] [--json]   (definition JSON on stdin)",
  "orb automation run <id> [--json]",
  "orb automation pause <id> [--json]",
  "orb automation resume <id> [--json]",
  "orb automation rm <id> [--json]",
]

let automationUsage = """
  orb automation — fetch items on a schedule, process them in steps, and
  deliver the result

  USAGE:
  \(usageBlock(automationUsageLines))

  An automation runs trigger -> source (optional) -> steps (zero or more)
  -> sink. Only items not seen in its previous run reach the steps. The
  only sink today is task candidates: the last step proposes tasks for you
  to accept or dismiss in Orbe, and it needs a source (currentSet or
  newArrivals) and at least one step. A proposal belongs to its link
  across all automations.
  set reads the definition from stdin, the same JSON as the definition of
  the MCP tool set_automation:
  {"name", "trigger", "source", "steps", "sink"}; source is optional.
    trigger  {"everyMinutes": 30}  or  {"dailyAt": ["09:00", "13:00"]}
    source   {"command": "…", "directory": "/abs", "coverage": "…"}  or
             {"agent": "claude", "model": "…", "tools": ["mcp__<server>__<tool>"],
              "request": "…", "coverage": "…"}
             An agent may use only the MCP tools named in full; built-in
             tools, whole servers and wildcards are refused. Name only
             tools that read the source (never ones that send, update or
             delete, nor Orbe's own tools): the name is checked, not what
             the tool does.
             A command prints one JSON object per item:
             {"id","link","body","time"} (link http(s), time ISO 8601),
             and fails with a non-zero exit or a single {"error": "…"} line.
             coverage (required): "currentSet" when the source returns the
             whole current set (a proposal whose link leaves it is
             withdrawn), "newArrivals" when it returns only new items (a
             proposal stays until the last step resolves it), "everything"
             to skip the diff against the previous run (not for task
             candidates). With newArrivals, the start of the last
             successful run is passed as ORBE_SINCE (ISO 8601, UTC) to a
             command and as a sentence to an agent; fetch from then on
             (overlap is fine; Orbe drops seen ids). The first run has none.
    steps    [{"name": "…", "command": "…", "directory": "/abs"}  or
              {"name": "…", "agent": "claude", "model": "…", "instruction": "…"}]
             A step takes JSON lines and prints JSON lines (stdin for a
             command, Orbe's framed prompt for an agent). A step agent has
             no tools. Keep each item's id: a run fails when no line that
             reaches the last step carries an id of this run's items.
             Narrow with cheap steps (commands, haiku) before costly ones.
             Without model, the last step runs sonnet and the other steps
             and the source run haiku; an omitted model stays omitted, so
             reordering steps moves the default with them.
    sink     {"kind": "taskCandidates"}
             An agent last step is told the output form by Orbe: write in
             its instruction what makes a task and how to title and date
             it. A command last step prints
             {"propose": id, "title": "…", "due": "YYYY-MM-DD"} lines itself
             (it gets no open proposals, so it cannot resolve).
  To edit, take .definition from list --json, change it and pipe it whole:
    orb automation list --json | jq '.automations[] |
      select(.automationId==3) | .definition' | … | orb automation set 3
  set without <id> creates an automation and prints its id; with <id> it
  replaces the whole definition. Changing the source method, a step's
  method, model, instruction or command, or the sink stops a running run
  and makes the next run process every fetched item again.
  run starts a run now (paused automations too) and returns at once; the
  result shows up in list. pause stops only the schedule; resume restarts
  it.
  list prints one automation per line: id, state (active / paused /
  running), name, trigger, next run, last run. Per-step counts are in
  list --json.
  proposals prints one proposal per line: id, state, automation id, due,
  title, link.
  """

// MARK: - サブコマンド

func runAutomation(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": automationList(rest)
  case "proposals": automationProposals(rest)
  case "set": automationSet(rest)
  case "run":
    automationSimple(rest, verb: "run", method: "run_automation", done: "started automation")
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

private func exitIfHelp(_ args: [String]) {
  guard hasHelp(args) else { return }
  print(automationUsage)
  exit(0)
}

private func automationList(_ rest: [String]) -> Never {
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 0)
  let result = callOrExit("list_automations", [:])
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let automations = (result as? [String: Any])?["automations"] as? [[String: Any]] ?? []
  for automation in automations {
    let state =
      automation["running"] as? Bool == true
      ? "running" : automation["paused"] as? Bool == true ? "paused" : "active"
    let definition = automation["definition"] as? [String: Any]
    let runs = automation["runs"] as? [[String: Any]] ?? []
    print(
      [
        automation["automationId"], state, definition?["name"], triggerCell(definition?["trigger"]),
        automation["nextRunAt"],
        runs.first.map(runCell),
      ].map { $0.map(display) ?? "-" }.map(tsvCell).joined(separator: "\t"))
  }
  exit(0)
}

/// `every 30m` / `daily 09:00,13:00`。
private func triggerCell(_ raw: Any?) -> String? {
  guard let trigger = raw as? [String: Any] else { return nil }
  if let minutes = trigger["everyMinutes"] { return "every \(display(minutes))m" }
  if let times = trigger["dailyAt"] as? [String] { return "daily " + times.joined(separator: ",") }
  return nil
}

/// 前回の要約（`<開始> failed: <理由>` か `<開始> 12 fetched, 3 new, 1 proposed`）。
private func runCell(_ run: [String: Any]) -> String {
  let started = run["startedAt"].map(display) ?? "?"
  if let failure = run["failure"] as? String { return "\(started) failed: \(failure)" }
  let fetched = (run["source"] as? [String: Any])?["count"].map(display) ?? "0"
  let fresh = run["fresh"].map(display) ?? "0"
  let proposed = (run["sink"] as? [String: Any])?["proposed"].map(display) ?? "0"
  return "\(started) \(fetched) fetched, \(fresh) new, \(proposed) proposed"
}

private func automationProposals(_ rest: [String]) -> Never {
  exitIfHelp(rest)
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
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  let id = rest.isEmpty ? nil : automationIdArg(rest, verb: "set")
  let data = FileHandle.standardInput.readDataToEndOfFile()
  guard !data.isEmpty else { usageDie("automation set reads the definition JSON from stdin") }
  guard let definition = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    usageDie("automation set: stdin is not a JSON object")
  }
  var params: [String: Any] = ["definition": definition]
  if let id { params["automationId"] = id }
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
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  let id = automationIdArg(rest, verb: paused ? "pause" : "resume")
  let result = callOrExit("pause_automation", ["automationId": id, "paused": paused])
  if wantJSON {
    printJSON(result)
  } else {
    print("\(paused ? "paused" : "resumed") automation \(id)")
  }
  exit(0)
}

private func automationSimple(_ rest: [String], verb: String, method: String, done: String) -> Never
{
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  let id = automationIdArg(rest, verb: verb)
  let result = callOrExit(method, ["automationId": id])
  if wantJSON { printJSON(result) } else { print("\(done) \(id)") }
  exit(0)
}

/// 位置引数の automation id（正の整数）。
private func automationIdArg(_ args: [String], verb: String) -> Int {
  guard let raw = args.first else { usageDie("automation \(verb) requires <id>") }
  guard let id = Int(raw), id >= 1 else { usageDie("invalid automation id: \(raw)") }
  return id
}

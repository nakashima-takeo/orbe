import Foundation

// `orb automation <サブコマンド>` の実装と usage。定義は MCP の set_automation の definition と同じ形の JSON を標準入力で
// 受け、検証は control に任せる（部品はコマンドか agent かで項目が入れ子になるので、フラグに割ると検証が 2 か所に割れる）。

// MARK: - usage

let automationUsageLines = [
  "orb automation list [--json]",
  "orb automation proposals [<id>] [--json]",
  "orb automation set [<id> --version <n>] [--json]   (definition JSON on stdin)",
  "orb automation run <id> [--part <key>] [--json]",
  "orb automation runs <id> [--part <key>] [--before <recordId>] [--limit <n>] [--json]",
  "orb automation try <id> [--from <key>]... [--to <key>]... [--stdin] [--limit <n>] [--json]",
  "orb automation trial <id> [--wait] [--timeout-ms <ms>] [--json]",
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
  -> sink. Only items not seen in its previous run reach the steps. There
  are four sinks. Task candidates: the last step proposes tasks for you to
  accept or dismiss in Orbe; it needs a source (currentSet or newArrivals)
  and at least one step, and a proposal belongs to its link across all
  automations. Command: a command receives the lines that reach the sink;
  the source and the steps are optional. Report: the text the last step
  writes is kept as the result of the run; it needs at least one step.
  Agent: a throwaway claude does a job with the tools it names; the source
  and the steps are optional.
  set reads the definition from stdin, the same JSON as the definition of
  the MCP tool set_automation:
  {"name", "trigger", "source", "steps", "sink", "notify"}; source and
  notify are optional.
    trigger  {"everyMinutes": 30}  or  {"cron": "0 9 * * 1-5"}
             everyMinutes runs N minutes after the last run; one missed
             while the Mac slept or Orbe was not running runs once on
             waking. cron is "minute hour day month weekday" in the Mac's
             time zone and runs only at those times; a time missed while
             asleep is skipped. Fields take *, numbers, ranges a-b, steps
             */n, a-b/n and a/n, and lists with commas; months and
             weekdays also take names (JAN, MON; weekday 0 and 7 are
             Sunday). No @daily shorthands, no L W # ?. Leave the day or
             the weekday as *; an expression that never matches is
             refused. Weekdays at 9:00 is "0 9 * * 1-5"; every 10 minutes
             from 9:00 to 18:50 on weekdays is "*/10 9-18 * * 1-5".
    source   {"command": "…", "directory": "/abs", "coverage": "…"}  or
             {"agent": "claude", "model": "…", "tools": ["mcp__<server>__<tool>"],
              "request": "…", "coverage": "…"}
             An agent may use only the MCP tools named in full; built-in
             tools, whole servers and wildcards are refused. Name only
             tools that read the source (never ones that send, update or
             delete, nor Orbe's own tools): the name is checked, not what
             the tool does. Background agents start in a fresh empty directory
             on each run, so MCP servers registered to a directory (claude's
             local and project scopes) are unavailable.
             A command prints one JSON object per item:
             {"id","link","body","time"} (link http(s), time ISO 8601),
             prints nothing when there are none, and fails with a non-zero
             exit.
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
             The lines a step command or the sink command receives are text
             from outside, or what steps made from it, so instructions hidden
             in that text can reshape them, and Orbe does not check what they
             say: never evaluate their values as shell, nor pass them to an
             agent (claude -p and the like). To have an agent read them, make
             it a step (Orbe runs a step agent without tools). To have
             something done with tools, use the agent sink: Orbe's limits do
             not apply to claude -p started inside a command sink.
    sink     {"kind": "taskCandidates"}
             An agent last step is told the output form by Orbe: write in
             its instruction what makes a task and how to title and date
             it. The last step may give each proposal a workspace to attach
             the task to (Orbe lists the workspaces other than Home; without
             one the task goes to Home); say how to choose it in the
             instruction too. A command last step prints
             {"propose": id, "title": "…", "due": "YYYY-MM-DD",
              "workspace": <id from orb ws list --json>} lines itself (it
             gets neither the open proposals nor the workspace list, so it
             cannot resolve; workspace ids change on every launch, so look
             them up on each run instead of writing them into the command).
             Home's id or no workspace sends the task to Home. A line naming
             an id that is not a current workspace is dropped.
             {"kind": "command", "command": "…", "directory": "/abs",
              "timeoutMinutes": 10}
             The command gets the lines that reach it on stdin, one JSON
             object per line (the source's items when there are no steps).
             It runs only when at least one line arrives; with neither a
             source nor steps it runs on every trigger with empty stdin. A
             run fails when the last step prints lines but none is a JSON
             object, and when the command exits non-zero or hits its limit.
             ORBE_RUN_ID names the run and stays the same when Orbe retries a
             run that did not finish; record it at the end, not the start.
             Items of a failed run flow again in the next run, mixed with new
             ones: skip them by each line's "id" (steps keep the id).
             timeoutMinutes (1-60, default 2) bounds both the run time and the
             time without output. stdout is not read. Over 1 MiB of stdout or
             64 KiB of stderr cuts the command off and fails the run; send
             large output to /dev/null. Editing the definition does not make
             the next run process every fetched item again.
             {"kind": "report"}
             The output of the last step is the report, kept as text (up to
             2000 characters) in the run record; a command last step prints
             it on stdout. Its first line shows on the board's heading and in
             the notification. An agent last step gives it through Orbe's
             tool, kept short, or says there is nothing to report; a command
             that prints nothing, or an agent that says so, succeeds as
             "nothing to report". Editing
             the definition does not make the next run process every fetched
             item again.
             {"kind": "agent", "agent": "claude", "model": "…",
              "tools": ["Bash(gh search prs:*)", "mcp__<server>__<tool>"],
              "request": "…"}
             Each run starts a throwaway claude in the background (no tab)
             with Orbe's fixed frame and the request, and only the named
             tools. It starts only when at least one line reaches the sink (on
             every trigger with neither a source nor steps); the lines and
             their count never reach the agent, so have it look up its targets
             itself. tools names full MCP tool names and
             Bash(<command prefix>:*) rules only (the prefix has no , ( ) *);
             bare built-in tools, whole servers and wildcards are refused.
             Name as few as possible. Each run starts in a fresh empty
             directory. With Bash rules only, claude reads none of your
             settings, and it refuses commands that read a file outside that
             directory given as an argument, even when they match a named
             rule; to read such a file, name a command that reads it, such as
             a script. Once an MCP tool is named, it reads your settings to
             reach your MCP servers, so the tools you always allow in claude
             (MCP tools and Bash commands) and your hooks apply too, and it
             can read under your settings' additionalDirectories without
             naming anything. Instructions hidden in outside text the agent
             reads with its tools can make it use a writing tool it was given.
             Without model it runs sonnet; it is cut off after 10 minutes, or
             3 minutes without output. It gives its report through Orbe's
             tool, kept as the result of the run (the first line shows on the
             board's heading and in the notification); when there is nothing
             to do it says so and delivers nothing. A run fails when the agent
             says it cannot do it, ends without a result, crashes, hits its
             limit, or a named MCP tool is unavailable. A failed run, or
             one Orbe did not finish, starts the agent again on the next run
             (a post can be doubled). Editing the definition does not make the
             next run process every fetched item again. The request stays in
             automations.json; never put secrets in it.
    notify   "menuBar" or "notificationCenter"  (any sink; omit to stay
             silent)
             When a run delivers something (a proposal, a command run, a
             report, an agent run that had something to do), or on the first
             of consecutive failed runs, the automation's name and the result
             line show with a sound: in the menu bar, or in macOS Notification
             Center. Notification Center keeps one notification per
             automation; a new run replaces it. Setting notificationCenter
             makes macOS ask for Orbe's notification permission if it is not
             decided yet; without permission, the run shows in the menu bar.
             Clicking either opens the automation on Home's board. Runs that
             deliver nothing are not notified. Changing only notify does not
             stop a running run.
  To edit, take .definition and .version from list --json, change the
  definition and pipe it whole with that version:
    orb automation list --json | jq '.automations[] |
      select(.automationId==3) | .definition' | … | orb automation set 3 --version 4
  set without <id> creates an automation and prints its id; with <id> it
  replaces the whole definition, and is refused when the automation changed
  since that version. Keep each part's id to keep the part. Changing the source method, a step's
  method, model, instruction or command, or the sink stops a running run;
  with task candidates the next run also processes every fetched item
  again.
  run starts a run now (paused automations too) and returns at once; the
  result shows up in list. pause stops only the schedule; resume restarts
  it.
  try runs the parts on a copy and returns at once (nothing saved or notified;
  side effects are held). trial reads it per part; --wait exits 124 on timeout.
  list prints one automation per line: id, state (active / paused /
  running), name, trigger, next run, last run (from the run record:
  fetched and new when it has a source, then proposed, the command's
  ending, reported or nothing to report, or the agent's ending when the
  sink recorded one).
  Per-step counts are in list --json. runs prints past runs newest first,
  one per line (record id, then the run), and "next <recordId>" when more
  remain; pass it as --before for the next page.
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
    let nodes = automation["parts"] as? [String: [String: Any]] ?? [:]
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
        scheduleCell(definition?["parts"] as? [[String: Any]] ?? [], next: next?.key),
        next?.at, lastRunCell(nodes),
      ].map { $0.map(display) ?? "-" }.map(tsvCell).joined(separator: "\t"))
  }
  exit(0)
}

/// 次に来る部品の予定（`every 30m` / `cron 0 9 * * 1-5`）。ほかに予定のある部品があれば ` +N`、予定のある部品が無ければ
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
  let data = FileHandle.standardInput.readDataToEndOfFile()
  guard !data.isEmpty else { usageDie("automation set reads the definition JSON from stdin") }
  guard let definition = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    usageDie("automation set: stdin is not a JSON object")
  }
  var params: [String: Any] = ["definition": definition]
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

private func automationRun(_ rest: [String]) -> Never {
  exitIfAutomationHelp(rest)
  var args = rest
  let nodeKey = takeOption(&args, "--part", requires: "a <key> value")
  rejectLeftovers(args, positionals: 1)
  let id = automationIdArg(args, verb: "run")
  var params: [String: Any] = ["automationId": id]
  if let nodeKey { params["partKey"] = nodeKey }
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

/// 位置引数の automation id（正の整数）。
func automationIdArg(_ args: [String], verb: String) -> Int {
  guard let raw = args.first else { usageDie("automation \(verb) requires <id>") }
  guard let id = Int(raw), id >= 1 else { usageDie("invalid automation id: \(raw)") }
  return id
}

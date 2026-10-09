import Foundation

// `orb intake <サブコマンド>` の実装と usage。定義は MCP の set_intake と同じ形の JSON を標準入力で受け、検証は control に
// 任せる（取得はコマンドか agent かで項目が入れ子になるので、フラグに割ると検証が 2 か所に割れる）。

// MARK: - usage

let intakeUsageLines = [
  "orb intake list [--json]",
  "orb intake proposals [<id>] [--json]",
  "orb intake set [<id>] [--json]   (definition JSON on stdin)",
  "orb intake run <id> [--json]",
  "orb intake pause <id> [--json]",
  "orb intake resume <id> [--json]",
  "orb intake rm <id> [--json]",
]

let intakeUsage = """
  orb intake — fetch items on a schedule and let an agent propose tasks

  USAGE:
  \(usageBlock(intakeUsageLines))

  An intake fetches items (a shell command or a light agent with the tools
  you name), passes only items not seen in its previous run to a judging
  agent, and keeps the tasks it proposes for you to accept or dismiss in
  Orbe. A proposal belongs to its link across all intakes.
  set reads the definition from stdin, the same JSON as the MCP tool
  set_intake: {"name", "fetch", "judge", "when"}, all four required.
    fetch  {"command": "…", "directory": "/abs"}  or
           {"agent": "claude", "model": "…", "tools": ["mcp__…"], "request": "…"}
           A command prints one JSON object per item:
           {"id","link","body","time"} (link http(s), time ISO 8601),
           and fails with a non-zero exit or a single {"error": "…"} line.
    judge  {"agent": "claude", "model": "…", "instruction": "…"}
    when   {"everyMinutes": 30}  or  {"dailyAt": ["09:00", "13:00"]}
  set without <id> creates an intake and prints its id; with <id> it
  replaces the whole definition. Changing fetch or judge stops a running
  run and makes the next run judge every fetched item again.
  run starts a run now (paused intakes too) and returns at once; the result
  shows up in list. pause stops only the schedule; resume restarts it.
  list prints one intake per line: id, state (active / paused / running),
  name, when, next run, last run.
  proposals prints one proposal per line: id, state, intake id, due,
  title, link.
  """

// MARK: - サブコマンド

func runIntake(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": intakeList(rest)
  case "proposals": intakeProposals(rest)
  case "set": intakeSet(rest)
  case "run": intakeSimple(rest, verb: "run", method: "run_intake", done: "started intake")
  case "pause": intakePause(rest, paused: true)
  case "resume": intakePause(rest, paused: false)
  case "rm": intakeSimple(rest, verb: "rm", method: "delete_intake", done: "removed intake")
  case nil:
    print(intakeUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(intakeUsage)
      exit(0)
    }
    usageDie("unknown intake command: \(other)")
  }
}

private func exitIfHelp(_ args: [String]) {
  guard hasHelp(args) else { return }
  print(intakeUsage)
  exit(0)
}

private func intakeList(_ rest: [String]) -> Never {
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 0)
  let result = callOrExit("list_intakes", [:])
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let intakes = (result as? [String: Any])?["intakes"] as? [[String: Any]] ?? []
  for intake in intakes {
    let state =
      intake["running"] as? Bool == true
      ? "running" : intake["paused"] as? Bool == true ? "paused" : "active"
    let runs = intake["runs"] as? [[String: Any]] ?? []
    print(
      [
        intake["intakeId"], state, intake["name"], whenCell(intake["when"]), intake["nextRunAt"],
        runs.first.map(runCell),
      ].map { $0.map(display) ?? "-" }.map(tsvCell).joined(separator: "\t"))
  }
  exit(0)
}

/// `every 30m` / `daily 09:00,13:00`。
private func whenCell(_ raw: Any?) -> String? {
  guard let when = raw as? [String: Any] else { return nil }
  if let minutes = when["everyMinutes"] { return "every \(display(minutes))m" }
  if let times = when["dailyAt"] as? [String] { return "daily " + times.joined(separator: ",") }
  return nil
}

/// 前回の要約（`<開始> failed: <理由>` か `<開始> 12 fetched, 3 new, 1 proposed`）。
private func runCell(_ run: [String: Any]) -> String {
  let started = run["startedAt"].map(display) ?? "?"
  if let failure = run["failure"] as? String { return "\(started) failed: \(failure)" }
  let fetched = (run["fetch"] as? [String: Any])?["items"].map(display) ?? "0"
  let fresh = run["newItems"].map(display) ?? "0"
  let proposed = (run["judge"] as? [String: Any])?["proposed"].map(display) ?? "0"
  return "\(started) \(fetched) fetched, \(fresh) new, \(proposed) proposed"
}

private func intakeProposals(_ rest: [String]) -> Never {
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  var params: [String: Any] = [:]
  if !rest.isEmpty { params["intakeId"] = intakeIdArg(rest, verb: "proposals") }
  let result = callOrExit("list_intake_proposals", params)
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let proposals = (result as? [String: Any])?["proposals"] as? [[String: Any]] ?? []
  for proposal in proposals {
    print(
      [
        proposal["proposalId"], proposal["state"], proposal["intakeId"], proposal["due"],
        proposal["title"], proposal["link"],
      ].map { $0.map(display) ?? "-" }.map(tsvCell).joined(separator: "\t"))
  }
  exit(0)
}

private func intakeSet(_ rest: [String]) -> Never {
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  let id = rest.isEmpty ? nil : intakeIdArg(rest, verb: "set")
  let data = FileHandle.standardInput.readDataToEndOfFile()
  guard !data.isEmpty else { usageDie("intake set reads the definition JSON from stdin") }
  guard var params = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    usageDie("intake set: stdin is not a JSON object")
  }
  if let id { params["intakeId"] = id }
  let result = callOrExit("set_intake", params)
  if wantJSON {
    printJSON(result)
  } else if let id {
    print("updated intake \(id)")
  } else {
    let intake = (result as? [String: Any])?["intake"] as? [String: Any]
    print(intake?["intakeId"] as? Int ?? -1)
  }
  exit(0)
}

private func intakePause(_ rest: [String], paused: Bool) -> Never {
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  let id = intakeIdArg(rest, verb: paused ? "pause" : "resume")
  let result = callOrExit("pause_intake", ["intakeId": id, "paused": paused])
  if wantJSON { printJSON(result) } else { print("\(paused ? "paused" : "resumed") intake \(id)") }
  exit(0)
}

private func intakeSimple(_ rest: [String], verb: String, method: String, done: String) -> Never {
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  let id = intakeIdArg(rest, verb: verb)
  let result = callOrExit(method, ["intakeId": id])
  if wantJSON { printJSON(result) } else { print("\(done) \(id)") }
  exit(0)
}

/// 位置引数の intake id（正の整数）。
private func intakeIdArg(_ args: [String], verb: String) -> Int {
  guard let raw = args.first else { usageDie("intake \(verb) requires <id>") }
  guard let id = Int(raw), id >= 1 else { usageDie("invalid intake id: \(raw)") }
  return id
}

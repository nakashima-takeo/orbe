import Foundation

// `orb agent <サブコマンド>` の実装と usage。`runAgent` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

// MARK: - usage

let agentUsageLines = [
  "orb agent list [--json]",
  "orb agent spawn [<agent>] [--workspace <id|current>] [--dir <path>] [--timeout-ms <ms>] [--json]",
  "orb agent resume <agent> <session-id> [--workspace <id|current>] [--dir <path>] [--timeout-ms <ms>] [--json]",
  "orb agent prompt <tab> (--text <text> | --stdin) [--timeout-ms <ms>] [--json]",
]

let agentUsage = """
  orb agent — list, launch and talk to the detected agent CLIs

  USAGE:
  \(usageBlock(agentUsageLines))

  spawn / resume open a new tab that runs the agent the way the GUI does, with
  the login shell PATH injected: spawn execs the resolved absolute path, resume
  runs the agent's own resume form and lets that PATH resolve the name.
  <agent> defaults to the target
  workspace's effective default-agent. --workspace opens in that workspace
  **without bringing it to the front**; use `orb tab focus <tab>` to go there.
  Both wait until the agent reports it is ready (its first idle) and then print
  ` ready (session <id>)`; --json carries ready:true and agentSessionId. Agents
  that cannot report idle (codex / agy) return at once with ready:false.
  <session-id> also comes from `orb tab list --json` (agentSessionId).
  --timeout-ms defaults to 30000; timing out exits 124 with ready:false and
  timedOut:true — the tab is open, the agent just has not reported yet.
  prompt sends <text> plus enter to the agent in <tab> and blocks until the
  agent stops: exit 0 when it finishes (state done), 3 when it asks something
  (state waiting; answer with `orb tab key`), 4 when the session ends (state
  clear), 124 on timeout (default 3600000 ms). Without --json, stdout is the
  agent's message only (empty if none). A working or waiting agent is refused
  with -32000 and nothing is sent. --text / --stdin follow `orb tab send`.
  """

// MARK: - サブコマンド

func runAgent(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": agentList(rest)
  case "spawn": agentSpawn(rest)
  case "resume": agentResume(rest)
  case "prompt": agentPrompt(rest)
  case nil:
    print(agentUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(agentUsage)
      exit(0)
    }
    usageDie("unknown agent command: \(other)")
  }
}

/// 検出済みエージェントを列挙する。検出ゼロはエラーにしない（`list_agents` は空配列を返す契約）。
private func agentList(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(agentUsage)
    exit(0)
  }
  rejectLeftovers(rest, positionals: 0)
  let result = callOrExit("list_agents", [:])
  if wantJSON {
    printJSON(result)
  } else {
    let agents = (result as? [String: Any])?["agents"] as? [[String: Any]] ?? []
    for agent in agents {
      print("\(agent["command"] as? String ?? "?")\t\(agent["path"] as? String ?? "")")
    }
  }
  exit(0)
}

private func agentSpawn(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(agentUsage)
    exit(0)
  }
  var args = rest
  let dir = takeOption(&args, "--dir", requires: "a <path> value")
  let workspaceId = takeWorkspaceId(&args)
  let timeoutMs = takeIntOption(&args, "--timeout-ms", requires: "a positive <milliseconds>")
  rejectLeftovers(args, positionals: 1)
  var params: [String: Any] = [:]
  if let agent = args.first { params["command"] = agent }
  if let workspaceId { params["workspaceId"] = workspaceId }
  if let dir { params["cwd"] = dir }
  if let timeoutMs { params["timeoutMs"] = timeoutMs }
  report(callOrExit("spawn_agent", params), verb: "spawned")
}

/// 既存セッションを再開する。不正な session ID（`a;rm -rf /` 等）は control が -32602 で弾く
/// ——CLI は文字集合を複製しない。
private func agentResume(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(agentUsage)
    exit(0)
  }
  var args = rest
  let dir = takeOption(&args, "--dir", requires: "a <path> value")
  let workspaceId = takeWorkspaceId(&args)
  let timeoutMs = takeIntOption(&args, "--timeout-ms", requires: "a positive <milliseconds>")
  rejectLeftovers(args, positionals: 2)
  guard args.count == 2 else { usageDie("agent resume requires <agent> and <session-id>") }
  var params: [String: Any] = ["command": args[0], "sessionId": args[1]]
  if let workspaceId { params["workspaceId"] = workspaceId }
  if let dir { params["cwd"] = dir }
  if let timeoutMs { params["timeoutMs"] = timeoutMs }
  report(callOrExit("resume_agent", params), verb: "resumed")
}

/// `spawn_agent` / `resume_agent` の共通応答（`{tabId, workspaceId, agent, ready, …}`）を出す。
/// 時間切れでも spawn は成功しているので人間向けの行は出し、理由は stderr へ（exit 124）。
private func report(_ result: Any, verb: String) -> Never {
  let d = result as? [String: Any]
  let timedOut = d?["timedOut"] as? Bool == true
  if wantJSON {
    printJSON(result)
  } else {
    let command = (d?["agent"] as? [String: Any])?["command"] as? String ?? "?"
    var line =
      "\(verb) \(command) in tab \(d?["tabId"] as? Int ?? -1) "
      + "(ws \(d?["workspaceId"] as? Int ?? -1))"
    if d?["ready"] as? Bool == true {
      line += " ready" + ((d?["agentSessionId"] as? String).map { " (session \($0))" } ?? "")
    }
    print(line)
    if timedOut { stderrLine("timed out waiting for the agent to become ready") }
  }
  exit(timedOut ? 124 : 0)
}

/// エージェントへ問うて止まるまで待つ。`<tab>` は必須（自タブへ問う形は無意味なので `ORBE_TAB`
/// に落ちない）。help は値の席を抜き取った後に見る（`tab send` と同じ理由）。
private func agentPrompt(_ rest: [String]) -> Never {
  var args = rest
  let text = takeOption(&args, "--text", requires: "a value (use --stdin for text starting with -)")
  let useStdin = takeFlag(&args, "--stdin")
  let timeoutMs = takeIntOption(&args, "--timeout-ms", requires: "a positive <milliseconds>")
  if hasHelp(args) {
    print(agentUsage)
    exit(0)
  }
  requireTextSource(text: text, useStdin: useStdin, verb: "agent prompt")
  rejectLeftovers(args, positionals: 1)
  guard let arg = args.first, let tab = Int(arg) else {
    usageDie("agent prompt requires a <tab> id")
  }

  var params: [String: Any] = ["tabId": tab, "text": text ?? readStdinText()]
  if let timeoutMs { params["timeoutMs"] = timeoutMs }
  let result = callOrExit("prompt_agent", params)
  let d = result as? [String: Any]
  if d?["timedOut"] as? Bool == true { timedOutDie(result) }
  if wantJSON {
    printJSON(result)
  } else {
    print(d?["message"] as? String ?? "")
  }
  switch d?["state"] as? String {
  case "waiting": exit(3)
  case "clear": exit(4)
  default: exit(0)
  }
}

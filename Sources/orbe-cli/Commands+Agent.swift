import Foundation

// `orb agent <サブコマンド>` の実装と usage。`runAgent` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

// MARK: - usage

let agentUsageLines = [
  "orb agent list [--json]",
  "orb agent spawn [<agent>] [--workspace <id|current>] [--dir <path>] [--json]",
  "orb agent resume <agent> <session-id> [--workspace <id|current>] [--dir <path>] [--json]",
]

let agentUsage = """
  orb agent — list and launch the detected agent CLIs

  USAGE:
  \(usageBlock(agentUsageLines))

  spawn / resume open a new tab that runs the agent the way the GUI does
  (resolved absolute path, login shell PATH). <agent> defaults to the target
  workspace's effective default-agent. --workspace opens in that workspace
  **without bringing it to the front**; use `orb pane focus <pane>` to go there.
  <session-id> comes from `orb pane list --json` (agentSessionId) or from
  `orb wait --kind agent_state --json`.
  """

// MARK: - サブコマンド

func runAgent(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": agentList(rest)
  case "spawn": agentSpawn(rest)
  case "resume": agentResume(rest)
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
  rejectLeftovers(args, positionals: 1)
  var params: [String: Any] = [:]
  if let agent = args.first { params["command"] = agent }
  if let workspaceId { params["workspaceId"] = workspaceId }
  if let dir { params["cwd"] = dir }
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
  rejectLeftovers(args, positionals: 2)
  guard args.count == 2 else { usageDie("agent resume requires <agent> and <session-id>") }
  var params: [String: Any] = ["command": args[0], "sessionId": args[1]]
  if let workspaceId { params["workspaceId"] = workspaceId }
  if let dir { params["cwd"] = dir }
  report(callOrExit("resume_agent", params), verb: "resumed")
}

/// `spawn_agent` / `resume_agent` の共通応答（`{paneId, tabId, workspaceId, agent}`）を出す。
private func report(_ result: Any, verb: String) -> Never {
  if wantJSON {
    printJSON(result)
  } else {
    let d = result as? [String: Any]
    let command = (d?["agent"] as? [String: Any])?["command"] as? String ?? "?"
    print(
      "\(verb) \(command) in pane \(d?["paneId"] as? Int ?? -1) "
        + "(tab \(d?["tabId"] as? Int ?? -1), ws \(d?["workspaceId"] as? Int ?? -1))")
  }
  exit(0)
}

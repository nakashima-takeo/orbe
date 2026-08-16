import Foundation

// `orb tab <サブコマンド>` の実装と usage。`runTab` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

let tabUsageLines = [
  "orb tab new [--workspace <id|current>] [--dir <path>] [--cmd \"…\"]",
  "orb tab close [<tab>]",
]

let tabUsage = """
  orb tab — open and close tabs in the running instance

  USAGE:
  \(usageBlock(tabUsageLines))

  tab new opens in the active workspace unless --workspace <id> is given.
  tab close defaults to the current tab (via ORBE_PANE); outside a Orbe pane,
  pass an explicit <tab> id (see: orb pane list).
  """

func runTab(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "new": tabNew(rest)
  case "close": tabClose(rest)
  case nil:
    print(tabUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(tabUsage)
      exit(0)
    }
    usageDie("unknown tab command: \(other)")
  }
}

private func tabNew(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(tabUsage)
    exit(0)
  }
  var args = rest
  let dir = takeOption(&args, "--dir", requires: "a <path> value")
  let cmd = takeOption(&args, "--cmd", requires: "a value")
  let workspaceId = takeWorkspaceId(&args)
  rejectLeftovers(args, positionals: 0)
  var params: [String: Any] = [:]
  if let workspaceId { params["workspaceId"] = workspaceId }
  if let dir { params["cwd"] = dir }
  if let cmd { params["command"] = cmd }
  let result = callOrExit("spawn", params)
  if wantJSON {
    printJSON(result)
  } else {
    print("opened tab, pane \((result as? [String: Any])?["paneId"] as? Int ?? -1)")
  }
  exit(0)
}

private func tabClose(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(tabUsage)
    exit(0)
  }
  rejectLeftovers(rest, positionals: 1)
  let tabId: Int
  if let first = rest.first {
    guard let id = Int(first) else { usageDie("invalid tab id: \(first)") }
    tabId = id
  } else {
    guard let pane = resolveCurrentPane(), let resolved = tabIdForPane(pane) else {
      usageDie("no tab in context — pass a tab id (see: orb pane list)")
    }
    tabId = resolved
  }
  let result = callOrExit("close_tab", ["tabId": tabId])
  if wantJSON { printJSON(result) } else { print("closed tab \(tabId)") }
  exit(0)
}

import Foundation

// `orb ws <サブコマンド>` の実装。`runWorkspace` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

func runWorkspace(_ args: [String]) -> Never {
  if args.isEmpty || hasHelp(args) {
    print(wsUsage)
    exit(args.isEmpty ? 2 : 0)
  }
  let rest = Array(args.dropFirst())
  switch args[0] {
  case "list": wsList(rest)
  case "new": wsNew(rest)
  case "rename": wsRename(rest)
  case "dir": wsDir(rest)
  case "switch": wsSwitch(rest)
  case "rm": wsRemove(rest)
  default: usageDie("unknown ws command: \(args[0])")
  }
}

private func wsList(_ rest: [String]) -> Never {
  rejectLeftovers(rest, positionals: 0)
  let result = callOrExit("list_workspaces", [:])
  if wantJSON {
    printJSON(result)
  } else {
    let list = (result as? [String: Any])?["workspaces"] as? [[String: Any]] ?? []
    for ws in list {
      let mark = (ws["active"] as? Bool == true) ? "*" : " "
      let id = ws["id"] as? Int ?? -1
      let name = ws["name"] as? String ?? "?"
      let root = ws["rootPath"] as? String ?? ""
      print("\(mark) \(id)\t\(name)\t\(root)")
    }
  }
  exit(0)
}

private func wsNew(_ args: [String]) -> Never {
  var rest = args
  let dir = takeOption(&rest, "--dir", requires: "a <path> value")
  rejectLeftovers(rest, positionals: 1)
  guard let name = rest.first else { usageDie("ws new requires <name>") }
  var params: [String: Any] = ["name": name]
  if let dir { params["rootPath"] = dir }
  let result = callOrExit("create_workspace", params)
  if wantJSON {
    printJSON(result)
  } else {
    let d = result as? [String: Any]
    print("created workspace \(d?["workspaceId"] as? Int ?? -1): \(d?["name"] as? String ?? name)")
  }
  exit(0)
}

private func wsRename(_ rest: [String]) -> Never {
  rejectLeftovers(rest, positionals: 2)
  guard rest.count >= 2 else { usageDie("ws rename requires <id|current> <name>") }
  let id = resolveWorkspaceId(rest[0])
  let name = rest[1]
  let result = callOrExit("rename_workspace", ["workspaceId": id, "name": name])
  if wantJSON { printJSON(result) } else { print("renamed workspace \(id) -> \(name)") }
  exit(0)
}

private func wsDir(_ rest: [String]) -> Never {
  rejectLeftovers(rest, positionals: 2)
  guard rest.count >= 2 else { usageDie("ws dir requires <id|current> <path>") }
  let id = resolveWorkspaceId(rest[0])
  let path = rest[1]
  let result = callOrExit("set_workspace_root", ["workspaceId": id, "rootPath": path])
  if wantJSON { printJSON(result) } else { print("set workspace \(id) dir -> \(path)") }
  exit(0)
}

private func wsSwitch(_ rest: [String]) -> Never {
  rejectLeftovers(rest, positionals: 1)
  guard let arg = rest.first, let id = Int(arg) else {
    usageDie("ws switch requires a numeric <id>")
  }
  let result = callOrExit("activate_workspace", ["workspaceId": id])
  if wantJSON { printJSON(result) } else { print("switched to workspace \(id)") }
  exit(0)
}

private func wsRemove(_ rest: [String]) -> Never {
  rejectLeftovers(rest, positionals: 1)
  guard let arg = rest.first else { usageDie("ws rm requires <id|current>") }
  let id = resolveWorkspaceId(arg)
  let result = callOrExit("remove_workspace", ["workspaceId": id])
  if wantJSON { printJSON(result) } else { print("removed workspace \(id)") }
  exit(0)
}

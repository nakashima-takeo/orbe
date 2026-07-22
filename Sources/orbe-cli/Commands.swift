import Foundation

// config / ws サブコマンドの実装。各サブコマンドは -> Never で終端し、exit で終了コードを返す。
// 手書きディスパッチ（argv[1]=ドメイン→ここ、argv[2]=サブコマンド）。

// MARK: - config

func runConfig(_ args: [String]) -> Never {
  // --help はサブコマンドが自分の usage を出す（config set --help → configSetUsage）。ここで握らない。
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": configList(rest)
  case "get": configGet(rest)
  case "set": configSet(rest)
  case "unset": configUnset(rest)
  case nil:
    print(configUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(configUsage)
      exit(0)
    }
    usageDie("unknown config command: \(other)")
  }
}

private func configList(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(configUsage)
    exit(0)
  }
  var args = rest
  let target = takeWorkspaceTarget(&args)
  var params: [String: Any] = [:]
  if case .id(let n) = target { params["workspaceId"] = n }
  let result = callOrExit("config_list", params)
  if wantJSON {
    printJSON(result)
  } else {
    let settings = (result as? [String: Any])?["settings"] as? [[String: Any]] ?? []
    for row in settings {
      let key = row["key"] as? String ?? "?"
      let value = display(row["value"] ?? NSNull())
      let scope = row["scope"] as? String ?? "?"
      print("\(key) = \(value) [\(scope)]")
    }
  }
  exit(0)
}

private func configGet(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(configUsage)
    exit(0)
  }
  var args = rest
  let target = takeWorkspaceTarget(&args)
  guard let key = args.first, !key.hasPrefix("-") else { usageDie("config get requires <key>") }
  var params: [String: Any] = [:]
  if case .id(let n) = target { params["workspaceId"] = n }
  let result = callOrExit("config_list", params)
  let settings = (result as? [String: Any])?["settings"] as? [[String: Any]] ?? []
  guard let row = settings.first(where: { $0["key"] as? String == key }) else {
    usageDie("unknown config key: \(key)")
  }
  if wantJSON { printJSON(row) } else { print(display(row["value"] ?? NSNull())) }
  exit(0)
}

private func configSet(_ args: [String]) -> Never {
  if hasHelp(args) {
    print(configSetUsage)
    exit(0)
  }
  var rest = args
  let target = takeWorkspaceTarget(&rest)
  guard rest.count >= 2 else { usageDie("config set requires <key> <value>") }
  let key = rest[0]
  // key の妥当性・値型は control の config_list を SSOT に引く（CLI 側で二重管理しない）。
  let settings = (callOrExit("config_list", [:]) as? [String: Any])?["settings"] as? [[String: Any]]
  guard let row = settings?.first(where: { $0["key"] as? String == key }) else {
    usageDie("unknown config key: \(key)")
  }
  let value = typedConfigValue(type: row["type"] as? String, key: key, raw: rest[1])
  // .none→global；.active/.id→workspace（.id は対象 WS も送る）。
  var params: [String: Any] = ["key": key, "value": value]
  let scope: String
  switch target {
  case .none: scope = "global"
  case .active: scope = "workspace"
  case .id(let n):
    scope = "workspace"
    params["workspaceId"] = n
  }
  params["scope"] = scope
  let result = callOrExit("config_set", params)
  if wantJSON {
    printJSON(result)
  } else {
    print("ok: \(key) = \(display(value)) [\(scope)]")
  }
  exit(0)
}

/// 設定 1 項目の上書きを解除して継承へ戻す（wire は `config_set` の `value: null`）。global スコープでは
/// global 明示値を除去する。`--workspace` でその WS の上書きを解除する。
private func configUnset(_ args: [String]) -> Never {
  if hasHelp(args) {
    print(configUsage)
    exit(0)
  }
  var rest = args
  let target = takeWorkspaceTarget(&rest)
  guard let key = rest.first, !key.hasPrefix("-") else { usageDie("config unset requires <key>") }
  var params: [String: Any] = ["key": key, "value": NSNull()]
  let scope: String
  switch target {
  case .none: scope = "global"
  case .active: scope = "workspace"
  case .id(let n):
    scope = "workspace"
    params["workspaceId"] = n
  }
  params["scope"] = scope
  let result = callOrExit("config_set", params)
  if wantJSON {
    printJSON(result)
  } else {
    print("unset: \(key) [\(scope)]")
  }
  exit(0)
}

/// control の config_list が返す type（int/bool/enum）で wire 値型を決める。パース失敗は usage エラー。
private func typedConfigValue(type: String?, key: String, raw: String) -> Any {
  switch type {
  case "int":
    guard let n = Int(raw) else { usageDie("\(key) expects an integer, got: \(raw)") }
    return n
  case "bool":
    guard let b = parseBool(raw) else {
      usageDie("\(key) expects true/false/on/off/1/0, got: \(raw)")
    }
    return b
  default:  // enum（theme / font-family / default-agent）は文字列
    return raw
  }
}

// MARK: - ws

func runWorkspace(_ args: [String]) -> Never {
  if args.isEmpty || hasHelp(args) {
    print(wsUsage)
    exit(args.isEmpty ? 2 : 0)
  }
  let rest = Array(args.dropFirst())
  switch args[0] {
  case "list": wsList()
  case "new": wsNew(rest)
  case "rename": wsRename(rest)
  case "dir": wsDir(rest)
  case "switch": wsSwitch(rest)
  case "rm": wsRemove(rest)
  default: usageDie("unknown ws command: \(args[0])")
  }
}

private func wsList() -> Never {
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
  let dir = takeOption(&rest, "--dir")
  if dir == nil, rest.contains("--dir") { usageDie("--dir requires a <path> value") }
  guard let name = rest.first, !name.hasPrefix("-") else { usageDie("ws new requires <name>") }
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
  guard rest.count >= 2 else { usageDie("ws rename requires <id|current> <name>") }
  let id = resolveWorkspaceId(rest[0])
  let name = rest[1]
  let result = callOrExit("rename_workspace", ["workspaceId": id, "name": name])
  if wantJSON { printJSON(result) } else { print("renamed workspace \(id) -> \(name)") }
  exit(0)
}

private func wsDir(_ rest: [String]) -> Never {
  guard rest.count >= 2 else { usageDie("ws dir requires <id|current> <path>") }
  let id = resolveWorkspaceId(rest[0])
  let path = rest[1]
  let result = callOrExit("set_workspace_root", ["workspaceId": id, "rootPath": path])
  if wantJSON { printJSON(result) } else { print("set workspace \(id) dir -> \(path)") }
  exit(0)
}

private func wsSwitch(_ rest: [String]) -> Never {
  guard let arg = rest.first, let id = Int(arg) else {
    usageDie("ws switch requires a numeric <id>")
  }
  let result = callOrExit("activate_workspace", ["workspaceId": id])
  if wantJSON { printJSON(result) } else { print("switched to workspace \(id)") }
  exit(0)
}

private func wsRemove(_ rest: [String]) -> Never {
  guard let arg = rest.first else { usageDie("ws rm requires <id|current>") }
  let id = resolveWorkspaceId(arg)
  let result = callOrExit("remove_workspace", ["workspaceId": id])
  if wantJSON { printJSON(result) } else { print("removed workspace \(id)") }
  exit(0)
}

// MARK: - pane

func runPane(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": paneList(rest)
  case "split": paneSplit(rest)
  case "close": paneClose(rest)
  case "focus": paneFocus(rest)
  case nil:
    print(paneUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(paneUsage)
      exit(0)
    }
    usageDie("unknown pane command: \(other)")
  }
}

private func paneList(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(paneUsage)
    exit(0)
  }
  var args = rest
  let target = takeWorkspaceTarget(&args)
  let result = callOrExit("list_panes", [:])
  var panes = (result as? [String: Any])?["panes"] as? [[String: Any]] ?? []
  if case .id(let n) = target { panes = panes.filter { $0["workspaceId"] as? Int == n } }
  if wantJSON {
    printJSON(["panes": panes])
  } else {
    for p in panes {
      let mark = (p["focused"] as? Bool == true) ? "*" : " "
      let pid = p["paneId"] as? Int ?? -1
      let wid = p["workspaceId"] as? Int ?? -1
      let tid = p["tabId"] as? Int ?? -1
      let title = p["title"] as? String ?? ""
      let cwd = display(p["cwd"] ?? NSNull())
      let agent = display(p["agentState"] ?? NSNull())
      print("\(mark) \(pid)\tws:\(wid)\ttab:\(tid)\t\(title)\t\(cwd)\t\(agent)")
    }
  }
  exit(0)
}

private func paneSplit(_ rest: [String]) -> Never {
  // split では `-h` は上下分割フラグ。help は `--help` のみで出す（他コマンドの hasHelp とは別扱い）。
  if rest.contains("--help") {
    print(paneSplitUsage)
    exit(0)
  }
  var args = rest
  let direction = paneSplitDirection(&args)  // -h=上下(down) / -v・既定=左右(right)
  guard let pane = resolvePaneArg(args) else { paneContextDie() }
  let result = callOrExit("split_pane", ["paneId": pane, "direction": direction])
  if wantJSON {
    printJSON(result)
  } else {
    print("split pane \(pane) -> \((result as? [String: Any])?["paneId"] as? Int ?? -1)")
  }
  exit(0)
}

private func paneClose(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(paneUsage)
    exit(0)
  }
  guard let pane = resolvePaneArg(rest) else { paneContextDie() }
  let result = callOrExit("close_pane", ["paneId": pane])
  if wantJSON { printJSON(result) } else { print("closed pane \(pane)") }
  exit(0)
}

private func paneFocus(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(paneUsage)
    exit(0)
  }
  // focus は自己指定が無意味なため位置引数必須（現ペイン既定を取らない）。
  guard let arg = rest.first, !arg.hasPrefix("-"), let pane = Int(arg) else {
    usageDie("pane focus requires a <pane> id")
  }
  let result = callOrExit("focus_pane", ["paneId": pane])
  if wantJSON { printJSON(result) } else { print("focused pane \(pane)") }
  exit(0)
}

// MARK: - tab

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
  let dir = takeOption(&args, "--dir")
  if dir == nil, args.contains("--dir") { usageDie("--dir requires a <path> value") }
  let cmd = takeOption(&args, "--cmd")
  if cmd == nil, args.contains("--cmd") { usageDie("--cmd requires a value") }
  let target = takeWorkspaceTarget(&args)
  var params: [String: Any] = [:]
  if case .id(let n) = target { params["workspaceId"] = n }
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
  let tabId: Int
  if let first = rest.first, !first.hasPrefix("-") {
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

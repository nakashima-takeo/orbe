import Foundation

// `orb pane <サブコマンド>` の実装。`runPane` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

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
  let workspaceId = takeWorkspaceId(&args)
  rejectLeftoverFlags(args, positionals: 0)
  let result = callOrExit("list_panes", [:])
  var panes = (result as? [String: Any])?["panes"] as? [[String: Any]] ?? []
  if let workspaceId { panes = panes.filter { $0["workspaceId"] as? Int == workspaceId } }
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
  rejectLeftoverFlags(args, positionals: 0)
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
  rejectLeftoverFlags(rest, positionals: 0)
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
  rejectLeftoverFlags(rest, positionals: 0)
  // focus は自己指定が無意味なため位置引数必須（現ペイン既定を取らない）。
  guard let arg = rest.first, let pane = Int(arg) else {
    usageDie("pane focus requires a <pane> id")
  }
  let result = callOrExit("focus_pane", ["paneId": pane])
  if wantJSON { printJSON(result) } else { print("focused pane \(pane)") }
  exit(0)
}

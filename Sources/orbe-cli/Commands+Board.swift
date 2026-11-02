import Foundation

// `orb board <サブコマンド>` の実装と usage。ウィジェットの種類の検証は control に任せる（知っている種類は control の断りが返す）。

// MARK: - usage

let boardUsageLines = [
  "orb board list <id|current> [--json]",
  "orb board add <id|current> <kind> [--json]",
  "orb board rm <id|current> <kind> [--json]",
]

let boardUsage = """
  orb board — choose what the board of a workspace shows

  USAGE:
  \(usageBlock(boardUsageLines))

  The board is a screen of the workspace beside its tabs. Only a workspace
  with a board takes these commands (`orb ws list --json` shows hasBoard).
  KINDS: automation (automations: the request field, the list and the
  right pane). A board holds each kind at most once.
  add appends the widget; adding a widget already there changes nothing.
  rm removes it; removing a widget not there changes nothing. Removing
  automation keeps the automations themselves (`orb automation list`).
  Each command prints the resulting widgets, one kind per line.
  """

// MARK: - サブコマンド

func runBoard(_ args: [String]) -> Never {
  if args.isEmpty || hasHelp(args) {
    print(boardUsage)
    exit(args.isEmpty ? 2 : 0)
  }
  let rest = Array(args.dropFirst())
  switch args[0] {
  case "list": boardList(rest)
  case "add": boardChange(rest, verb: "add", method: "add_board_widget")
  case "rm": boardChange(rest, verb: "rm", method: "remove_board_widget")
  default: usageDie("unknown board command: \(args[0])")
  }
}

private func boardList(_ rest: [String]) -> Never {
  rejectLeftovers(rest, positionals: 1)
  guard let arg = rest.first else { usageDie("board list requires <id|current>") }
  printWidgets(callOrExit("list_board_widgets", ["workspaceId": resolveWorkspaceId(arg)]))
}

private func boardChange(_ rest: [String], verb: String, method: String) -> Never {
  rejectLeftovers(rest, positionals: 2)
  guard rest.count == 2 else { usageDie("board \(verb) requires <id|current> <kind>") }
  printWidgets(callOrExit(method, ["workspaceId": resolveWorkspaceId(rest[0]), "kind": rest[1]]))
}

private func printWidgets(_ result: Any) -> Never {
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let widgets = (result as? [String: Any])?["widgets"] as? [[String: Any]] ?? []
  for widget in widgets {
    print(tsvCell(widget["kind"].map(display) ?? "-"))
  }
  exit(0)
}

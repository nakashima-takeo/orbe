import Foundation

// `orb board <サブコマンド>` の実装と usage。部品の種類の検証は control に任せる（知っている種類は control の断りが返す）。

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
  KINDS: automation (automations: the heading, request field, list and
  detail). A board holds each kind at most once.
  add appends the part; adding a part already there changes nothing.
  rm removes it; removing a part not there changes nothing. Removing
  automation keeps the automations themselves (`orb automation list`).
  Each command prints the resulting parts, one kind per line.
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
  case "add": boardChange(rest, verb: "add", method: "add_board_part")
  case "rm": boardChange(rest, verb: "rm", method: "remove_board_part")
  default: usageDie("unknown board command: \(args[0])")
  }
}

private func boardList(_ rest: [String]) -> Never {
  rejectLeftovers(rest, positionals: 1)
  guard let arg = rest.first else { usageDie("board list requires <id|current>") }
  printParts(callOrExit("list_board_parts", ["workspaceId": resolveWorkspaceId(arg)]))
}

private func boardChange(_ rest: [String], verb: String, method: String) -> Never {
  rejectLeftovers(rest, positionals: 2)
  guard rest.count == 2 else { usageDie("board \(verb) requires <id|current> <kind>") }
  printParts(callOrExit(method, ["workspaceId": resolveWorkspaceId(rest[0]), "kind": rest[1]]))
}

private func printParts(_ result: Any) -> Never {
  if wantJSON {
    printJSON(result)
    exit(0)
  }
  let parts = (result as? [String: Any])?["parts"] as? [[String: Any]] ?? []
  for part in parts {
    print(tsvCell(part["kind"].map(display) ?? "-"))
  }
  exit(0)
}

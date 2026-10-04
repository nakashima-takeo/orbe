import Foundation

// `orb task <サブコマンド>` の実装と usage。`runTask` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

// MARK: - usage

let taskUsageLines = [
  "orb task list [--workspace <id|current>] [--json]",
  "orb task add <title> [--status <s>] [--priority <p>] [--due <YYYY-MM-DD>]"
    + " [--workspace <id|current> | --no-workspace] [--waiting <reason>] [--memo <text>]"
    + " [--issue <owner/name#N>]... [--pr <owner/name#N>]... [--json]",
  "orb task set <id> [--title <t>] [--status <s>] [--priority <p>] [--due <date> | --no-due]"
    + " [--workspace <id|current> | --no-workspace] [--waiting <reason> | --no-waiting]"
    + " [--memo <text> | --no-memo] [--issue <owner/name#N>]... [--pr <owner/name#N>]..."
    + " [--no-links] [--json]",
  "orb task move <id> (--before <id> | --after <id>) [--json]",
  "orb task rm <id> [--json]",
]

/// ステータスと優先度の語彙。検証は control が持ち CLI は素通しするので、ここは人が読むための写し。
let taskStatusNames = ["todo", "in_progress", "done"]
let taskPriorityNames = ["high", "medium", "low"]

let taskUsage = """
  orb task — the task list shared by you and your agents

  USAGE:
  \(usageBlock(taskUsageLines))

  STATUSES: \(taskStatusNames.joined(separator: ", "))
  PRIORITIES: \(taskPriorityNames.joined(separator: ", ")) (default medium)
  The list is one ordered column across all workspaces; add appends to the end
  and prints the new task id. Ids are never reused.
  add without --workspace attaches the task to the workspace of the tab you run
  it in (ORBE_TAB), or to no workspace outside a Orbe tab. --workspace current
  means the workspace in front, which is not necessarily your tab's.
  --no-workspace attaches to no workspace.
  --waiting marks the task as waiting on something (kept apart from status);
  --status done clears it, and a done task cannot be waiting. --no-due /
  --no-waiting / --no-workspace / --no-memo clear the value.
  --issue / --pr link GitHub issues and PRs to the task (repeatable); the first
  one you pass is the main link. set replaces all links with the ones you pass,
  and --no-links removes them all. An issue or PR can be linked to only one
  task (unlink it from the other task first).
  list prints one task per line: id, status, priority, due, workspace, title,
  waiting reason, links (`-` when absent; links read issue:owner/name#221,pr:…).
  """

// MARK: - サブコマンド

func runTask(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": taskList(rest)
  case "add": taskAdd(rest)
  case "set": taskSet(rest)
  case "move": taskMove(rest)
  case "rm": taskRemove(rest)
  case nil:
    print(taskUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(taskUsage)
      exit(0)
    }
    usageDie("unknown task command: \(other)")
  }
}

private func taskList(_ rest: [String]) -> Never {
  var args = rest
  let workspaceId = takeWorkspaceId(&args)
  exitIfHelp(args)
  rejectLeftovers(args, positionals: 0)
  var params: [String: Any] = [:]
  if let workspaceId { params["workspaceId"] = workspaceId }
  let result = callOrExit("list_tasks", params)
  if wantJSON {
    printJSON(result)
  } else {
    let tasks = (result as? [String: Any])?["tasks"] as? [[String: Any]] ?? []
    for task in tasks {
      let waiting = (task["waiting"] as? [String: Any])?["reason"]
      let links = (task["links"] as? [[String: Any]])?.map(linkCell).joined(separator: ",")
      print(
        [
          task["taskId"], task["status"], task["priority"], task["due"], task["workspaceName"],
          task["title"], waiting, links,
        ].map { $0.map(display) ?? "-" }.map(tsvCell).joined(separator: "\t"))
    }
  }
  exit(0)
}

/// 結び付き 1 つの表示（`issue:owner/name#221`）。
private func linkCell(_ link: [String: Any]) -> String {
  let field = { (key: String) in link[key].map(display) ?? "-" }
  return "\(field("kind")):\(field("repo"))#\(field("number"))"
}

private func taskAdd(_ rest: [String]) -> Never {
  var args = rest
  var params = takeFields(&args, update: false)
  exitIfHelp(args)
  rejectLeftovers(args, positionals: 1)
  guard let title = args.first else { usageDie("task add requires <title>") }
  params["title"] = title
  // 呼び出し元タブは、追加者の agent 名と、workspace を省いたときの付き先を control が引くのに使う。
  if let tab = resolveCurrentTab() { params["callerTabId"] = tab }
  let result = callOrExit("add_task", params)
  if wantJSON {
    printJSON(result)
  } else {
    let task = (result as? [String: Any])?["task"] as? [String: Any]
    print(task?["taskId"] as? Int ?? -1)
  }
  exit(0)
}

private func taskSet(_ rest: [String]) -> Never {
  var args = rest
  var params = takeFields(&args, update: true)
  if let title = takeOption(&args, "--title", requires: "a <title>") { params["title"] = title }
  exitIfHelp(args)
  rejectLeftovers(args, positionals: 1)
  let id = taskIdArg(args, verb: "set")
  guard !params.isEmpty else { usageDie("task set requires at least one field to change") }
  params["taskId"] = id
  let result = callOrExit("update_task", params)
  if wantJSON { printJSON(result) } else { print("updated task \(id)") }
  exit(0)
}

private func taskMove(_ rest: [String]) -> Never {
  var args = rest
  let before = takeIntOption(&args, "--before", requires: "a task <id>")
  let after = takeIntOption(&args, "--after", requires: "a task <id>")
  exitIfHelp(args)
  rejectLeftovers(args, positionals: 1)
  let id = taskIdArg(args, verb: "move")
  var params: [String: Any] = ["taskId": id]
  switch (before, after) {
  case (let anchor?, nil): params["beforeTaskId"] = anchor
  case (nil, let anchor?): params["afterTaskId"] = anchor
  default: usageDie("task move requires exactly one of --before / --after")
  }
  let result = callOrExit("move_task", params)
  if wantJSON { printJSON(result) } else { print("moved task \(id)") }
  exit(0)
}

private func taskRemove(_ rest: [String]) -> Never {
  exitIfHelp(rest)
  rejectLeftovers(rest, positionals: 1)
  let id = taskIdArg(rest, verb: "rm")
  let result = callOrExit("delete_task", ["taskId": id])
  if wantJSON { printJSON(result) } else { print("removed task \(id)") }
  exit(0)
}

// MARK: - 引数

/// help は**値の席を抜き取った後**の残りで見る（`tab send` と同じ）。メモや待ちの理由は任意の文字列で、
/// 引数列全体を走査すると `--memo -h` の値が help と読まれ、何も変えないまま exit 0 になる。抜き取った
/// 後なら値の席の `-h` は `takeOption` のダッシュ拒否に落ちて exit 2 で止まる。
private func exitIfHelp(_ args: [String]) {
  guard hasHelp(args) else { return }
  print(taskUsage)
  exit(0)
}

/// `add` と `set` が共有する項目フラグを params へ写す。`--no-*` の解除フラグは `set` だけが取る
/// （`add` は `--no-workspace` だけ——付き先の省略に意味があるのは workspace だけ）。
private func takeFields(_ args: inout [String], update: Bool) -> [String: Any] {
  var params: [String: Any] = [:]
  if let status = takeOption(&args, "--status", requires: "a <status>") {
    params["status"] = status
  }
  if let priority = takeOption(&args, "--priority", requires: "a <priority>") {
    params["priority"] = priority
  }
  let due: (inout [String]) -> Any? = { takeOption(&$0, "--due", requires: "a <YYYY-MM-DD> date") }
  let waiting: (inout [String]) -> Any? = { takeOption(&$0, "--waiting", requires: "a <reason>") }
  let memo: (inout [String]) -> Any? = { takeOption(&$0, "--memo", requires: "a <text>") }
  if update {
    params["due"] = takeClearable(&args, "--due", take: due)
    params["waitingReason"] = takeClearable(&args, "--waiting", take: waiting)
    // メモは「無い」と「空」を区別しないので、外すのは空文字への置き換え。
    params["memo"] = takeClearable(&args, "--memo", cleared: "", take: memo)
  } else {
    params["due"] = due(&args)
    params["waitingReason"] = waiting(&args)
    params["memo"] = memo(&args)
  }
  params["workspaceId"] = takeClearable(&args, "--workspace") { takeWorkspaceId(&$0) }
  let links = takeLinks(&args)
  if update, takeFlag(&args, "--no-links") {
    guard links.isEmpty else { usageDie("pass only one of --issue / --pr / --no-links") }
    params["links"] = [Any]()
  } else if !links.isEmpty {
    params["links"] = links
  }
  return params
}

/// `--issue` と `--pr` を、引数に現れた順のまま抜き取る（先頭が主になるので、種別ごとに抜き出して
/// つなぐと順が崩れる）。値の席の規則は `takeOption` と同じ。`owner/name#N` は最後の `#` で割り、後ろが
/// 正の整数でなければ usage エラー。`owner/name` の形は control が確かめる。
private func takeLinks(_ args: inout [String]) -> [[String: Any]] {
  let kinds = ["--issue": "issue", "--pr": "pr"]
  var links: [[String: Any]] = []
  while let index = args.firstIndex(where: { kinds[$0] != nil }) {
    let flag = args[index]
    var rest = Array(args[index...])
    guard let raw = takeOption(&rest, flag, requires: "an <owner/name#N>") else { break }
    args.replaceSubrange(index..., with: rest)
    guard let hash = raw.lastIndex(of: "#"), let number = Int(raw[raw.index(after: hash)...]),
      number >= 1
    else { usageDie("\(flag) requires an <owner/name#N>: \(raw)") }
    links.append(["kind": kinds[flag]!, "repo": String(raw[..<hash]), "number": number])
  }
  return links
}

/// `--x <v>` と `--no-x` の対。どちらも無ければ nil、両方なら usage エラー。`--no-x` は `cleared`
/// （既定は JSON の null）になる。
private func takeClearable(
  _ args: inout [String], _ name: String, cleared: Any = NSNull(),
  take: (inout [String]) -> Any?
) -> Any? {
  let value = take(&args)
  let clear = takeFlag(&args, "--no-" + name.dropFirst(2))
  switch (value, clear) {
  case (.some, true): usageDie("pass only one of \(name) / --no-\(name.dropFirst(2))")
  case (.some(let v), false): return v
  case (nil, true): return cleared
  case (nil, false): return nil
  }
}

/// 位置引数の task id（正の整数）。
private func taskIdArg(_ args: [String], verb: String) -> Int {
  guard let raw = args.first else { usageDie("task \(verb) requires <id>") }
  guard let id = Int(raw), id >= 1 else { usageDie("invalid task id: \(raw)") }
  return id
}

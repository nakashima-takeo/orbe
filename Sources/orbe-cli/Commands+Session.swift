import Foundation
import OrbeSessionLog

// `orb session <サブコマンド>` の実装と usage。エージェントセッションの寿命ログ（`session_log`）を読み、
// 「閉じたまま戻っていない」群を導き、`restore_sessions` で戻す。群（同じ事故で閉じたもの）を扱う入口は
// ここと MCP だけで、Orbe 本体の ⇧⌘T は 1 件ずつ戻す。

// MARK: - usage

let sessionUsageLines = [
  "orb session log [--since <iso|30m|2h|3d>] [--until <iso>] [--limit <n>] [--session <id>] [--json]",
  "orb session closed [--since <iso|30m|2h|3d>] [--json]",
  "orb session restore <session-id>... [--json]",
  "orb session restore --at <iso> [--json]",
]

let sessionUsage = """
  orb session — closed agent sessions: log, what is still gone, restore

  USAGE:
  \(usageBlock(sessionUsageLines))

  log prints the session lifetime log (opened / closed) in file order, one
  event per line: ts, event, command, sessionId, workspace, cwd, title,
  origin[/reason] (title is the tab's title when it closed; title and origin
  are `-` on opened). --since takes an ISO 8601 time or a relative
  <n>m / <n>h / <n>d; --until is ISO 8601 only. --limit defaults to
  \(SessionLogLimits.defaultLimit) (max \(SessionLogLimits.maxLimit)); when older
  events are dropped, stderr says so.
  closed lists sessions whose last event is closed and that are not open in
  any tab now, newest first, in groups: closes with the same origin within 5 s
  form one group (closed by you never groups). --since keeps the groups whose
  `at` is at or after that time. --json is {groups:[{at, origin, sessions}]};
  `at` is the group's oldest close and is what --at takes.
  restore brings sessions back as dormant tickets into their workspace
  (matched by rootPath; created from the log when missing), placed like a new
  tab: at the end of the run of tabs from the same worktree, else last. They
  are not selected or brought to the front; each resumes when its tab is mounted
  (in the active workspace the next tab selection mounts the pending tabs one
  by one; in a background workspace, when that workspace is activated).
  --at <iso> restores every session still gone from the groups with that `at`
  (the value `session closed` prints, matched exactly after normalizing to
  milliseconds; a value without them means .000) — this is the way to bring
  many back at once. Exit 1 if any id is unknown to the log.
  """

// MARK: - サブコマンド

func runSession(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "log": sessionLog(rest)
  case "closed": sessionClosed(rest)
  case "restore": sessionRestore(rest)
  case nil:
    print(sessionUsage)
    exit(2)
  case .some(let other):
    if hasHelp([other]) {
      print(sessionUsage)
      exit(0)
    }
    usageDie("unknown session command: \(other)")
  }
}

private func sessionLog(_ rest: [String]) -> Never {
  var args = rest
  let since = takeOption(&args, "--since", requires: "an ISO 8601 time or <n>m|h|d")
  let until = takeOption(&args, "--until", requires: "an ISO 8601 time")
  let limit = takeIntOption(&args, "--limit", requires: "a positive <n>")
  let session = takeOption(&args, "--session", requires: "a <session-id>")
  if hasHelp(args) {
    print(sessionUsage)
    exit(0)
  }
  rejectLeftovers(args, positionals: 0)

  var params: [String: Any] = [:]
  if let since { params["since"] = SessionEvent.iso8601(parseSinceOrDie(since)) }
  if let until { params["until"] = parseISOOrDie(until, flag: "--until") }
  if let limit { params["limit"] = limit }
  if let session { params["sessionId"] = session }
  let result = callOrExit("session_log", params)
  let d = result as? [String: Any]
  if d?["truncated"] as? Bool == true {
    stderrLine("truncated: older events omitted (raise --limit)")
  }
  if wantJSON {
    printJSON(result)
  } else {
    for event in decodeEvents(d) { print(eventLine(event)) }
  }
  exit(0)
}

private func sessionClosed(_ rest: [String]) -> Never {
  var args = rest
  let since = takeOption(&args, "--since", requires: "an ISO 8601 time or <n>m|h|d")
  if hasHelp(args) {
    print(sessionUsage)
    exit(0)
  }
  rejectLeftovers(args, positionals: 0)

  // 群は常に全 closed から切り、--since は群の `at` で後から絞る——切る範囲を変えると `at` が動き、
  // `session closed` が出した値を `restore --at` が解けなくなる。
  let cutoff = since.map { parseSinceOrDie($0) }
  let groups = closedGroups().filter { group in cutoff.map { group.at >= $0 } ?? true }
  if wantJSON {
    printJSON(["groups": groups.map(groupJSON)])
  } else {
    for group in groups {
      let n = group.sessions.count
      print(
        "\(group.atISO)\t\(n) \(n == 1 ? "session" : "sessions") closed (\(group.origin.rawValue))")
      for event in group.sessions {
        print(
          [
            "", event.agent.command, event.sessionId, event.workspace.name, event.cwd,
            event.closeReason ?? "-",
          ].map(cell).joined(separator: "\t"))
      }
    }
  }
  exit(0)
}

/// id の列挙か `--at <iso>` のどちらか一方で戻す。id ごとの status を出し、`unknown` が 1 つでもあれば
/// exit 1（RPC 自体は成功＝部分成功）。
private func sessionRestore(_ rest: [String]) -> Never {
  var args = rest
  let at = takeOption(&args, "--at", requires: "an ISO 8601 time (the `at` of `session closed`)")
  if hasHelp(args) {
    print(sessionUsage)
    exit(0)
  }
  rejectLeftovers(args, positionals: args.count)  // 位置引数は可変・`-` 始まり不可

  let ids: [String]
  if let at {
    guard args.isEmpty else { usageDie("pass either <session-id>... or --at <iso>, not both") }
    let atISO = parseISOOrDie(at, flag: "--at")
    // 同じ `at` の群は複数ありうる（origin の違う closed が同じミリ秒に落ちると群は分かれ、`at` は並ぶ）。
    let groups = closedGroups().filter { $0.atISO == atISO }
    guard !groups.isEmpty else { transportDie("no closed group at \(at)") }
    ids = groups.flatMap { $0.sessions.map(\.sessionId) }
  } else {
    guard !args.isEmpty else { usageDie("session restore requires <session-id>... or --at <iso>") }
    ids = args
  }

  let result = restoreSessions(ids)
  let rows = result["results"] as? [[String: Any]] ?? []
  if wantJSON {
    printJSON(result)
  } else {
    for row in rows {
      var line = "\(row["sessionId"] as? String ?? "?")\t\(row["status"] as? String ?? "?")"
      if let ws = row["workspaceId"] as? Int, let tab = row["tabId"] as? Int {
        line += "\tws:\(ws)\ttab:\(tab)"
      }
      print(line)
    }
  }
  exit(rows.contains { $0["status"] as? String == "unknown" } ? 1 : 0)
}

// MARK: - 導出（`closed` と `restore --at` が共有する）

/// `session_log`（上限いっぱい）と `list_tabs` から「閉じたまま戻っていない」群を新しい順に組む。
/// present は `list_tabs` の `agentSessionId`（live / 休眠とも）。
private func closedGroups() -> [SessionBurst] {
  let logResult =
    callOrExit("session_log", ["limit": SessionLogLimits.maxLimit]) as? [String: Any]
  if logResult?["truncated"] as? Bool == true {
    stderrLine("truncated: only the newest \(SessionLogLimits.maxLimit) events were read")
  }
  let events = decodeEvents(logResult)
  let tabs = (callOrExit("list_tabs", [:]) as? [String: Any])?["tabs"] as? [[String: Any]] ?? []
  let present = Set(tabs.compactMap { $0["agentSessionId"] as? String })
  return SessionLogQuery.closedGroups(events: events, present: present).reversed()
}

/// `restore_sessions` を 1 回の上限ごとに分けて呼び、`results` を連結した 1 つの result にする
/// （`seq` など他のキーは最後の応答のもの）。
private func restoreSessions(_ ids: [String]) -> [String: Any] {
  var merged: [String: Any] = [:]
  var rows: [[String: Any]] = []
  for start in stride(from: 0, to: ids.count, by: SessionLogLimits.restoreMaxIds) {
    let chunk = Array(ids[start..<min(start + SessionLogLimits.restoreMaxIds, ids.count)])
    guard let result = callOrExit("restore_sessions", ["sessionIds": chunk]) as? [String: Any]
    else { transportDie("invalid restore_sessions result") }
    rows += result["results"] as? [[String: Any]] ?? []
    merged = result
  }
  merged["results"] = rows
  return merged
}

/// `session_log` の result（wire 形の配列）を `SessionEvent` へ。形が違えば transport エラー。
private func decodeEvents(_ result: [String: Any]?) -> [SessionEvent] {
  guard let raw = result?["events"] as? [[String: Any]],
    let data = try? JSONSerialization.data(withJSONObject: raw),
    let events = try? JSONDecoder().decode([SessionEvent].self, from: data)
  else { transportDie("invalid session_log result") }
  return events
}

private func eventDicts(_ events: [SessionEvent]) -> [[String: Any]] {
  guard let data = try? JSONEncoder().encode(events),
    let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
  else { return [] }
  return dicts
}

private func groupJSON(_ group: SessionBurst) -> [String: Any] {
  ["at": group.atISO, "origin": group.origin.rawValue, "sessions": eventDicts(group.sessions)]
}

/// 人向けの 1 行: `ts\tevent\tcommand\tsessionId\tworkspace\tcwd\ttitle\torigin[/reason]`
/// （opened の title と origin は `-`）。
private func eventLine(_ event: SessionEvent) -> String {
  let name: String
  let title: String
  let ending: String
  switch event.kind {
  case .opened:
    name = "opened"
    title = "-"
    ending = "-"
  case .closed(let origin, let reason, let closeTitle):
    name = "closed"
    title = closeTitle ?? "-"
    ending = origin.rawValue + (reason.map { "/" + $0 } ?? "")
  }
  return [
    SessionEvent.iso8601(event.ts), name, event.agent.command, event.sessionId,
    event.workspace.name, event.cwd, title, ending,
  ].map(cell).joined(separator: "\t")
}

/// タブ区切りの行に載せるセル。タブは列を、改行は行を壊し、ESC 等は読み手の端末が解釈するため、
/// 制御文字はまとめて空白にする（title / reason は hook 由来、cwd は OSC 7 由来の任意文字列）。
private func cell(_ s: String) -> String {
  var scalars = String.UnicodeScalarView()
  for scalar in s.unicodeScalars {
    scalars.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar)
  }
  return String(scalars)
}

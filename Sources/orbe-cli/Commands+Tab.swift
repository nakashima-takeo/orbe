import Foundation

// `orb tab <サブコマンド>` の実装と usage。`runTab` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

// MARK: - usage

let tabUsageLines = [
  "orb tab list [--workspace <id|current>] [--json]",
  "orb tab new [--workspace <id|current>] [--dir <path>] [--cmd \"…\"]",
  "orb tab close [<tab>]",
  "orb tab focus <tab>",
  "orb tab text [<tab>] [--scrollback] [--json]",
  "orb tab send [<tab>] (--text <text> | --stdin)",
  "orb tab key [<tab>] --key <key>",
]

/// `tab key --key` が受ける名前付きキー。usage は socket 不達でも出す必要があるため control から
/// 引けず、`ControlKey` の表をここに写す。この写しのドリフトは `testTabHelpListsEveryKeyName` が
/// `ControlKey` の語彙と突き合わせて落とす（`KINDS:` / `KEYS:` の既存 2 例と同じ守り方）。
let tabKeyNames = [
  "enter", "return", "tab", "escape", "esc", "space", "backspace", "delete",
  "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
]

let tabUsage = """
  orb tab — open, inspect and manipulate tabs in the running instance

  USAGE:
  \(usageBlock(tabUsageLines))

  KEYS: \(tabKeyNames.joined(separator: ", "))
  Any single Unicode character works too (control characters and "+" do not);
  prefix with ctrl+ / alt+ / shift+ (ctrl+c). shift+ uppercases the letter
  (shift+a sends A). cmd+ is accepted on named keys only (rejected on a single
  character). A modified key may be consumed by the terminal's own keybinds
  before it reaches the tab.
  new opens in the active workspace unless --workspace <id> is given.
  <tab> defaults to the current tab (ORBE_TAB). Outside a Orbe tab, pass an
  explicit id (see: orb tab list). focus always requires an explicit <tab>.
  text prints the captured screen verbatim (no trailing newline is added).
  send takes exactly one of --text / --stdin and does not press enter — follow
  it with `orb tab key --key enter` to run what you sent. Pass text that starts
  with "-", or that is empty/whitespace only, through --stdin: a value in an
  option slot may not start with "-" or be blank.
  """

// MARK: - サブコマンド

func runTab(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": tabList(rest)
  case "new": tabNew(rest)
  case "close": tabClose(rest)
  case "focus": tabFocus(rest)
  case "text": tabText(rest)
  case "send": tabSend(rest)
  case "key": tabKey(rest)
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

private func tabList(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(tabUsage)
    exit(0)
  }
  var args = rest
  let workspaceId = takeWorkspaceId(&args)
  rejectLeftovers(args, positionals: 0)
  var result = (callOrExit("list_tabs", [:]) as? [String: Any]) ?? [:]
  var tabs = result["tabs"] as? [[String: Any]] ?? []
  if let workspaceId { tabs = tabs.filter { $0["workspaceId"] as? Int == workspaceId } }
  if wantJSON {
    result["tabs"] = tabs
    printJSON(result)
  } else {
    // 人間向けの `*` は「前面 workspace で選択中」——`active` は背景 workspace でも 1 枚 true なので、
    // 前面かは list_workspaces で確かめる。
    let front = activeWorkspaceId()
    for t in tabs {
      let wid = t["workspaceId"] as? Int ?? -1
      let mark = (t["active"] as? Bool == true && wid == front) ? "*" : " "
      let tid = t["tabId"] as? Int ?? -1
      let title = t["title"] as? String ?? ""
      let cwd = display(t["cwd"] ?? NSNull())
      let agent = display(t["agentState"] ?? NSNull())
      print("\(mark) \(tid)\tws:\(wid)\t\(title)\t\(cwd)\t\(agent)")
    }
  }
  exit(0)
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
    print("opened tab \((result as? [String: Any])?["tabId"] as? Int ?? -1)")
  }
  exit(0)
}

private func tabClose(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(tabUsage)
    exit(0)
  }
  rejectLeftovers(rest, positionals: 1)
  guard let tab = resolveTabArg(rest) else { tabContextDie() }
  let result = callOrExit("close_tab", ["tabId": tab])
  if wantJSON { printJSON(result) } else { print("closed tab \(tab)") }
  exit(0)
}

private func tabFocus(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(tabUsage)
    exit(0)
  }
  rejectLeftovers(rest, positionals: 1)
  // focus は自己指定が無意味なため位置引数必須（現タブ既定を取らない）。
  guard let arg = rest.first, let tab = Int(arg) else {
    usageDie("tab focus requires a <tab> id")
  }
  let result = callOrExit("focus_tab", ["tabId": tab])
  if wantJSON { printJSON(result) } else { print("focused tab \(tab)") }
  exit(0)
}

/// タブの画面テキストを取り出す。人間向けは **生テキストをそのまま** stdout へ流す
/// （`orb tab text > snapshot.txt` が画面を再現できることが要件なので改行を足さない・取らない）。
private func tabText(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(tabUsage)
    exit(0)
  }
  var args = rest
  let scrollback = takeFlag(&args, "--scrollback")
  rejectLeftovers(args, positionals: 1)
  guard let tab = resolveTabArg(args) else { tabContextDie() }
  let result = callOrExit("get_tab_text", ["tabId": tab, "scrollback": scrollback])
  if wantJSON {
    printJSON(result)
  } else {
    writeRaw((result as? [String: Any])?["text"] as? String ?? "")
  }
  exit(0)
}

/// タブへテキストを送る（ペースト相当。実行は `tab key --key enter` が別に担う）。
///
/// `--text` と `--stdin` はどちらか一方が必須。`--stdin` を明示必須にしているので、引数を
/// 省いたときに黙って標準入力を待つことはない。読み取りは**タブ解決の後**に置く——引数が
/// 不正なときに tty で待たせないため。
private func tabSend(_ rest: [String]) -> Never {
  // help は**値の席を抜き取った後**に見る。`--text` の値は任意のユーザーテキストなので、引数列
  // 全体を走査すると `--text -h` の値が help と読まれ、**何も送らないまま exit 0** になる
  // （`orb tab send --text "$X" && orb tab key --key enter` が enter だけ押す形）。抜き取った
  // 後なら値の席の `-h` は `takeOption` のダッシュ拒否に落ちて exit 2 で止まる。
  var args = rest
  let text = takeOption(&args, "--text", requires: "a value (use --stdin for text starting with -)")
  let useStdin = takeFlag(&args, "--stdin")
  if hasHelp(args) {
    print(tabUsage)
    exit(0)
  }
  requireTextSource(text: text, useStdin: useStdin, verb: "tab send")
  rejectLeftovers(args, positionals: 1)
  guard let tab = resolveTabArg(args) else { tabContextDie() }

  let payload = text ?? readStdinText()
  let result = callOrExit("send_text", ["tabId": tab, "text": payload])
  if wantJSON { printJSON(result) } else { print("sent to tab \(tab)") }
  exit(0)
}

/// タブへ名前付きキーを送る。未知キー名は control の `ControlKey.parse` が -32602 で弾く
/// （CLI が持つのは help 用の写しだけで、判定は複製しない）。
private func tabKey(_ rest: [String]) -> Never {
  var args = rest
  let key = takeOption(&args, "--key", requires: "a <key> name")  // help より先に値の席を抜く
  if hasHelp(args) {
    print(tabUsage)
    exit(0)
  }
  guard let key else { usageDie("tab key requires --key <key>") }
  rejectLeftovers(args, positionals: 1)
  guard let tab = resolveTabArg(args) else { tabContextDie() }
  let result = callOrExit("send_key", ["tabId": tab, "key": key])
  if wantJSON { printJSON(result) } else { print("sent key \(key) to tab \(tab)") }
  exit(0)
}

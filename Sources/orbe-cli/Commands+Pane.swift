import Foundation

// `orb pane <サブコマンド>` の実装と usage。`runPane` が argv[2] を手書きでディスパッチし、
// 各サブコマンドは -> Never で終端して exit で終了コードを返す。

// MARK: - usage

let paneUsageLines = [
  "orb pane list [--workspace <id|current>] [--json]",
  "orb pane split [<pane>] [-v | -h]",
  "orb pane close [<pane>]",
  "orb pane focus <pane>",
  "orb pane text [<pane>] [--scrollback] [--json]",
  "orb pane send [<pane>] (--text <text> | --stdin)",
  "orb pane key [<pane>] --key <key>",
]

/// `pane key --key` が受ける名前付きキー。usage は socket 不達でも出す必要があるため control から
/// 引けず、`ControlKey` の表をここに写す。この写しのドリフトは `testPaneHelpListsEveryKeyName` が
/// `ControlKey` の語彙と突き合わせて落とす（`KINDS:` / `KEYS:` の既存 2 例と同じ守り方）。
let paneKeyNames = [
  "enter", "return", "tab", "escape", "esc", "space", "backspace", "delete",
  "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
]

let paneUsage = """
  orb pane — inspect and manipulate panes in the running instance

  USAGE:
  \(usageBlock(paneUsageLines))

  KEYS: \(paneKeyNames.joined(separator: ", "))
  Any single Unicode character works too (control characters and "+" do not);
  prefix with ctrl+ / alt+ / shift+ (ctrl+c). shift+ uppercases the letter
  (shift+a sends A). cmd+ is accepted on named keys only (rejected on a single
  character); the terminal's own keybinds may consume it before the pane.
  <pane> defaults to the current pane (ORBE_PANE). Outside a Orbe pane, pass
  an explicit id (see: orb pane list). focus always requires an explicit <pane>.
  text prints the captured screen verbatim (no trailing newline is added).
  send takes exactly one of --text / --stdin and does not press enter — follow
  it with `orb pane key --key enter` to run what you sent. Pass text that starts
  with "-", or that is empty/whitespace only, through --stdin: a value in an
  option slot may not start with "-" or be blank.
  """

let paneSplitUsage = """
  orb pane split [<pane>] [-v | -h]

  Split <pane> (default: current pane via ORBE_PANE) into two.
    -v   split into left/right panes (vertical divider, like Cmd+D). default.
    -h   split into top/bottom panes (horizontal divider, like Cmd+Shift+D).
  """

// MARK: - サブコマンド

func runPane(_ args: [String]) -> Never {
  let rest = Array(args.dropFirst())
  switch args.first {
  case "list": paneList(rest)
  case "split": paneSplit(rest)
  case "close": paneClose(rest)
  case "focus": paneFocus(rest)
  case "text": paneText(rest)
  case "send": paneSend(rest)
  case "key": paneKey(rest)
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
  rejectLeftovers(args, positionals: 0)
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
  rejectLeftovers(args, positionals: 1)
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
  rejectLeftovers(rest, positionals: 1)
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
  rejectLeftovers(rest, positionals: 1)
  // focus は自己指定が無意味なため位置引数必須（現ペイン既定を取らない）。
  guard let arg = rest.first, let pane = Int(arg) else {
    usageDie("pane focus requires a <pane> id")
  }
  let result = callOrExit("focus_pane", ["paneId": pane])
  if wantJSON { printJSON(result) } else { print("focused pane \(pane)") }
  exit(0)
}

/// ペインの画面テキストを取り出す。人間向けは **生テキストをそのまま** stdout へ流す
/// （`orb pane text > snapshot.txt` が画面を再現できることが要件なので改行を足さない・取らない）。
private func paneText(_ rest: [String]) -> Never {
  if hasHelp(rest) {
    print(paneUsage)
    exit(0)
  }
  var args = rest
  let scrollback = takeFlag(&args, "--scrollback")
  rejectLeftovers(args, positionals: 1)
  guard let pane = resolvePaneArg(args) else { paneContextDie() }
  let result = callOrExit("get_pane_text", ["paneId": pane, "scrollback": scrollback])
  if wantJSON {
    printJSON(result)
  } else {
    writeRaw((result as? [String: Any])?["text"] as? String ?? "")
  }
  exit(0)
}

/// ペインへテキストを送る（ペースト相当。実行は `pane key --key enter` が別に担う）。
///
/// `--text` と `--stdin` はどちらか一方が必須。`--stdin` を明示必須にしているので、引数を
/// 省いたときに黙って標準入力を待つことはない。読み取りは**ペイン解決の後**に置く——引数が
/// 不正なときに tty で待たせないため。
///
/// 空入力の扱いが `--text` と非対称なのは意図的。`--text` は空白のみも弾く（`--text "$PROMPT"`
/// の `$PROMPT` が空になる形がそこで起きる）。`--stdin` は 0 バイトだけを弾き空白は通す——
/// `printf '%s' "$PROMPT" | orb pane send --stdin` の未設定は 0 バイトとして現れる一方、
/// ファイルや heredoc の正当な中身が空白・改行だけであることはあり得るから。
private func paneSend(_ rest: [String]) -> Never {
  // help は**値の席を抜き取った後**に見る。`--text` の値は任意のユーザーテキストなので、引数列
  // 全体を走査すると `--text -h` の値が help と読まれ、**何も送らないまま exit 0** になる
  // （`orb pane send --text "$X" && orb pane key --key enter` が enter だけ押す形）。抜き取った
  // 後なら値の席の `-h` は `takeOption` のダッシュ拒否に落ちて exit 2 で止まる。
  var args = rest
  let text = takeOption(&args, "--text", requires: "a value (use --stdin for text starting with -)")
  let useStdin = takeFlag(&args, "--stdin")
  if hasHelp(args) {
    print(paneUsage)
    exit(0)
  }
  if text != nil && useStdin { usageDie("pass only one of --text / --stdin") }
  guard text != nil || useStdin else { usageDie("pane send requires --text or --stdin") }
  rejectLeftovers(args, positionals: 1)
  guard let pane = resolvePaneArg(args) else { paneContextDie() }

  let payload: String
  if let text {
    payload = text
  } else {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { usageDie("--stdin got no input") }
    guard let decoded = String(data: data, encoding: .utf8) else {
      usageDie("--stdin is not valid UTF-8")
    }
    payload = decoded
  }
  let result = callOrExit("send_text", ["paneId": pane, "text": payload])
  if wantJSON { printJSON(result) } else { print("sent to pane \(pane)") }
  exit(0)
}

/// ペインへ名前付きキーを送る。未知キー名は control の `ControlKey.parse` が -32602 で弾く
/// （CLI が持つのは help 用の写しだけで、判定は複製しない）。
private func paneKey(_ rest: [String]) -> Never {
  var args = rest
  let key = takeOption(&args, "--key", requires: "a <key> name")  // help より先に値の席を抜く
  if hasHelp(args) {
    print(paneUsage)
    exit(0)
  }
  guard let key else { usageDie("pane key requires --key <key>") }
  rejectLeftovers(args, positionals: 1)
  guard let pane = resolvePaneArg(args) else { paneContextDie() }
  let result = callOrExit("send_key", ["paneId": pane, "key": key])
  if wantJSON { printJSON(result) } else { print("sent key \(key) to pane \(pane)") }
  exit(0)
}

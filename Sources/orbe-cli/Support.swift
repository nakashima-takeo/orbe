import Foundation

// orbe-cli の出力・終了・引数ヘルパと usage テキスト。main.swift（socket クライアント）・
// Commands.swift（サブコマンド）が共用する。終了コードは 0 成功 / 2 usage エラー / 1 RPC・接続エラー。

// MARK: - 出力・終了

/// トップの `--json` フラグ（read 出力は生 JSON、error は {"error":{code,message}}）。
var wantJSON = false

func printJSON(_ value: Any) {
  guard
    let data = try? JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
    let s = String(data: data, encoding: .utf8)
  else { return }
  print(s)
}

func stderrLine(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// usage エラー（引数不正）。終了コード 2。
func usageDie(_ message: String) -> Never {
  stderrLine("error: \(message)")
  exit(2)
}

/// JSON 値を人間可読な 1 語へ整形する（Bool は NSNumber と衝突するため CFBoolean で判定）。
func display(_ value: Any) -> String {
  if let n = value as? NSNumber {
    if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
    return n.stringValue
  }
  if value is NSNull { return "(unset)" }
  if let s = value as? String { return s }
  return String(describing: value)
}

/// control を叩き、成功なら result を返す。RPC/接続エラーは出力して終了コード 1 で抜ける。
func callOrExit(_ method: String, _ params: [String: Any]) -> Any {
  switch controlRequest(method: method, params: params) {
  case .ok(let result):
    return result
  case .rpcError(let code, let message):
    if wantJSON {
      printJSON(["error": ["code": code, "message": message]])
    } else {
      stderrLine("error \(code): \(message)")
    }
    exit(1)
  case .transport(let message):
    if wantJSON {
      printJSON(["error": ["code": -1, "message": message]])
    } else {
      stderrLine(message)
    }
    exit(1)
  }
}

// MARK: - 引数ヘルパ

/// `true/false/on/off/1/0` を Bool へ。それ以外は nil。
func parseBool(_ s: String) -> Bool? {
  switch s.lowercased() {
  case "true", "on", "1": return true
  case "false", "off", "0": return false
  default: return nil
  }
}

func hasHelp(_ args: [String]) -> Bool { args.contains("--help") || args.contains("-h") }

/// `--dir <path>` を抜き取る（残りを inout で縮める）。
func takeOption(_ args: inout [String], _ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  let value = args[i + 1]
  args.removeSubrange(i...(i + 1))
  return value
}

/// `--workspace` の有無を抜き取る。
func takeFlag(_ args: inout [String], _ name: String) -> Bool {
  guard let i = args.firstIndex(of: name) else { return false }
  args.remove(at: i)
  return true
}

/// `pane split` の分割方向を引数から決める（`args` から `-v`/`-h` を抜き取る）。
/// `-h`=上下（down）、`-v`／既定=左右（right）。両立指定は usage エラー。
/// help（`--help`）は呼び出し側が事前に握るため `-h` はここでは常に上下フラグ。
func paneSplitDirection(_ args: inout [String]) -> String {
  let wantH = takeFlag(&args, "-h")
  let wantV = takeFlag(&args, "-v")
  if wantH && wantV { usageDie("pass only one of -v / -h") }
  return wantH ? "down" : "right"
}

/// config / tab の `--workspace [<id>]`（optional-value）の解決結果。
enum WorkspaceTarget {
  case none  // --workspace 未指定
  case active  // --workspace のみ（値なし）
  case id(Int)  // --workspace <id>（<id> は数値か current）
}

/// `--workspace [<id>]` を抜き取る。直後トークンが `-` 始まりでなく数値か `current` に解決できるなら
/// 値として消費して `.id`、無ければ `.active`、フラグ自体が無ければ `.none`。
func takeWorkspaceTarget(_ args: inout [String]) -> WorkspaceTarget {
  guard let i = args.firstIndex(of: "--workspace") else { return .none }
  if i + 1 < args.count, !args[i + 1].hasPrefix("-"), let id = workspaceIdIfResolvable(args[i + 1])
  {
    args.removeSubrange(i...(i + 1))
    return .id(id)
  }
  args.remove(at: i)
  return .active
}

/// `<token>` が数値 workspace id か `current` なら解決した id を返す（それ以外 nil＝値として消費しない）。
func workspaceIdIfResolvable(_ token: String) -> Int? {
  if let n = Int(token) { return n }
  if token == "current" { return resolveWorkspaceId("current") }
  return nil
}

/// ペイン系コマンドの現ペイン既定。GUI が注入する `ORBE_PANE`（自ペイン id）を読む。
func resolveCurrentPane() -> Int? {
  ProcessInfo.processInfo.environment["ORBE_PANE"].flatMap(Int.init)
}

/// pane 位置引数（省略時 ORBE_PANE）を解決する。位置引数が非フラグなら数値化（不正は usage エラー）、
/// 無ければ現ペイン。どちらも無ければ nil（呼び出し側が `orb pane list` を促す誘導エラーへ）。
func resolvePaneArg(_ args: [String]) -> Int? {
  if let first = args.first, !first.hasPrefix("-") {
    guard let id = Int(first) else { usageDie("invalid pane id: \(first)") }
    return id
  }
  return resolveCurrentPane()
}

/// Orbe 外で対象ペイン省略時の誘導エラー（exit 2）。
func paneContextDie() -> Never {
  usageDie("no pane in context — pass a pane id (see: orb pane list)")
}

/// ORBE_PANE の所属タブ id を list_panes 走査で解決する（tab close の現タブ既定）。
func tabIdForPane(_ paneId: Int) -> Int? {
  let result = callOrExit("list_panes", [:])
  let panes = (result as? [String: Any])?["panes"] as? [[String: Any]] ?? []
  return panes.first { $0["paneId"] as? Int == paneId }?["tabId"] as? Int
}

/// `<id|current>` を workspace id へ解決する。`current` は list_workspaces の active:true 要素の id。
func resolveWorkspaceId(_ arg: String) -> Int {
  if let n = Int(arg) { return n }
  guard arg == "current" else { usageDie("invalid workspace id: \(arg)") }
  let result = callOrExit("list_workspaces", [:])
  guard
    let list = (result as? [String: Any])?["workspaces"] as? [[String: Any]],
    let active = list.first(where: { $0["active"] as? Bool == true }),
    let id = active["id"] as? Int
  else {
    stderrLine("no active workspace")
    exit(1)
  }
  return id
}

// MARK: - config key 一覧（usage テキスト表示用。key の妥当性・値型は control の config_list を SSOT に引く）

let allConfigKeys = [
  "font-size", "background-opacity", "background-blur", "cursor-style-blink", "theme",
  "font-family", "default-agent", "agent-state-icons", "dev-features",
]

// MARK: - usage テキスト

let topUsage = """
  orb — configure and control the running Orbe instance

  USAGE:
    orb config list [--workspace [<id>]] [--json]
    orb config get <key> [--workspace [<id>]] [--json]
    orb config set <key> <value> [--workspace [<id>]]
    orb config unset <key> [--workspace [<id>]]
    orb ws list [--json]
    orb ws new <name> [--dir <path>]
    orb ws rename <id|current> <name>
    orb ws dir <id|current> <path>
    orb ws switch <id>
    orb ws rm <id|current>
    orb pane list [--workspace <id>] [--json]
    orb pane split [<pane>] [-v | -h]
    orb pane close [<pane>]
    orb pane focus <pane>
    orb tab new [--workspace [<id>]] [--dir <path>] [--cmd "…"]
    orb tab close [<tab>]

  COMMON FLAGS:
    --json              machine-readable JSON output (read commands / errors)
    --workspace [<id>]  target a workspace (<id> or current; bare = active)
    --dir <path>        root/working directory (ws new / tab new)
    --cmd "…"           command to run in the new tab (tab new)

  pane / tab default to the current pane via ORBE_PANE. Outside a Orbe pane,
  pass an explicit id (see: orb pane list).
  Resolves the target instance from ORBE_STATE_DIR / ORBE_SOCK. Run inside a
  Orbe pane, or the control socket must be reachable; otherwise exits non-zero.
  Exit codes: 0 success, 2 usage error, 1 RPC/connection error.
  """

let paneUsage = """
  orb pane — inspect and manipulate panes in the running instance

  USAGE:
    orb pane list [--workspace <id>] [--json]
    orb pane split [<pane>] [-v | -h]
    orb pane close [<pane>]
    orb pane focus <pane>

  <pane> defaults to the current pane (ORBE_PANE). Outside a Orbe pane, pass
  an explicit id (see: orb pane list). focus always requires an explicit <pane>.
  """

let paneSplitUsage = """
  orb pane split [<pane>] [-v | -h]

  Split <pane> (default: current pane via ORBE_PANE) into two.
    -v   split into left/right panes (vertical divider, like Cmd+D). default.
    -h   split into top/bottom panes (horizontal divider, like Cmd+Shift+D).
  """

let tabUsage = """
  orb tab — open and close tabs in the running instance

  USAGE:
    orb tab new [--workspace [<id>]] [--dir <path>] [--cmd "…"]
    orb tab close [<tab>]

  tab new opens in the active workspace unless --workspace <id> is given.
  tab close defaults to the current tab (via ORBE_PANE); outside a Orbe pane,
  pass an explicit <tab> id (see: orb pane list).
  """

let configUsage = """
  orb config — read and set Orbe settings

  USAGE:
    orb config list [--workspace [<id>]] [--json]
    orb config get <key> [--workspace [<id>]] [--json]
    orb config set <key> <value> [--workspace [<id>]]
    orb config unset <key> [--workspace [<id>]]

  KEYS: \(allConfigKeys.joined(separator: ", "))
  --workspace targets a workspace: <id> (or current) for a specific one, bare
  --workspace for the active one. Without the flag, config set/unset writes global.
  All settings are workspace-overridable; unset clears an override (back to inherit).
  """

let configSetUsage = """
  orb config set <key> <value> [--workspace [<id>]]

  KEYS: \(allConfigKeys.joined(separator: ", "))
    font-size, background-opacity   integer
    background-blur, cursor-style-blink   true/false/on/off/1/0
    theme (auto/light/dark), font-family, default-agent   string
  --workspace <id> writes that workspace's override, bare --workspace the active
  one (default without the flag: global). default-agent is global-only.
  """

let wsUsage = """
  orb ws — manage workspaces

  USAGE:
    orb ws list [--json]
    orb ws new <name> [--dir <path>]
    orb ws rename <id|current> <name>
    orb ws dir <id|current> <path>
    orb ws switch <id>
    orb ws rm <id|current>
  """

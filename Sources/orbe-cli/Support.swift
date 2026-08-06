import Foundation

// orbe-cli の出力・終了・引数ヘルパと usage テキスト。main.swift（socket クライアント）・
// `Commands+<ドメイン>.swift`（サブコマンド）が共用する。終了コードは 0 成功 / 2 usage エラー / 1 RPC・接続エラー。

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

/// 接続・文脈解決の失敗（終了コード 1）。`--json` では RPC エラーと同じ `{"error":{code,message}}`
/// を stdout へ載せる——書式が経路によって割れると、機械可読を謳いながら一部の失敗だけ
/// パースできない出力になる。
func transportDie(_ message: String) -> Never {
  if wantJSON {
    printJSON(["error": ["code": -1, "message": message]])
  } else {
    stderrLine(message)
  }
  exit(1)
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
    transportDie(message)
  }
}

/// config key の行を control の `config_list` から引く（未知 key は usage エラー）。
/// get / set / unset が同じ SSOT・同じ文言・同じ終了コードで弾くための唯一の口。
/// `params` は読む層の指定で、`get` だけが `--workspace` の解決結果を渡す（set / unset は存在確認
/// だけなので層に依らない）。
func configRowOrDie(_ key: String, _ params: [String: Any] = [:]) -> [String: Any] {
  let settings =
    (callOrExit("config_list", params) as? [String: Any])?["settings"] as? [[String: Any]] ?? []
  guard let row = settings.first(where: { $0["key"] as? String == key }) else {
    usageDie("unknown config key: \(key)")
  }
  return row
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

/// 値必須オプション（`--dir <path>` / `--cmd "…"`）を抜き取る（残りを inout で縮める）。
/// フラグ自体が無ければ nil。値が無い・`-` 始まり・空（空白だけを含む）なら usage エラー
/// （`label` が期待する値の形）。
///
/// **値の席は空けられない。**`orb tab new --dir "$DIR" --cmd "$CMD"` の `$DIR` が空になる形が両方入る:
/// 引用符が無ければトークンごと消えて次のフラグが値に化け（`--dir --cmd claude` は cwd が `--cmd` で
/// `claude` が捨てられる）、引用符があれば空文字がそのまま cwd として通る。どちらも飲まれた側は
/// 残余に落ちないので `rejectLeftovers` では捕まらず、終了コードにも stdout にも stderr にも
/// 現れないまま、指定と違う cwd のタブ・rootPath が空の workspace ができる。
func takeOption(_ args: inout [String], _ name: String, requires label: String) -> String? {
  guard let i = args.firstIndex(of: name) else { return nil }
  guard i + 1 < args.count, !args[i + 1].hasPrefix("-"),
    !args[i + 1].trimmingCharacters(in: .whitespaces).isEmpty
  else {
    usageDie("\(name) requires \(label)")
  }
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

/// config の `--workspace [<id|current>]`（optional-value）の解決結果。書き込み先が 3 つ実在するので
/// 3 態を持つ。`--workspace` を取る pane / tab は `pane list` と `tab new` の 2 つだけで、そちらは
/// `takeWorkspaceId` が `<id|current>` 必須で扱う——この非対称は spec の
/// 表記（`docs/spec/orbe-cli.md` で config 系だけが値を省ける形に書かれている）に揃えたもの。
enum WorkspaceTarget {
  case none  // --workspace 未指定
  case active  // --workspace のみ（値なし）
  case id(Int)  // --workspace <id>（<id> は数値か current）
}

/// config の `--workspace [<id>]` を抜き取る。直後トークンが `-` 始まりでなく数値か `current` に
/// 解決できるなら値として消費して `.id`、無ければ `.active`、フラグ自体が無ければ `.none`。
///
/// `positionals` はそのサブコマンドが取る位置引数の数。bare と判定した後に残余がこれを超えるなら、
/// フラグ直後のトークンは値の意図だったので usage エラーにする。この判定が無いと順序で挙動が割れ、
/// 後置（`config set <key> <value> --workspace nosuch`）では解決できない指定が黙って捨てられ、
/// **指定したのと違う（アクティブな）workspace が書き換わる**。
func takeWorkspaceTarget(_ args: inout [String], positionals: Int) -> WorkspaceTarget {
  guard let i = args.firstIndex(of: "--workspace") else { return .none }
  let candidate = (i + 1 < args.count && !args[i + 1].hasPrefix("-")) ? args[i + 1] : nil
  if let candidate, let id = workspaceIdIfResolvable(candidate) {
    args.removeSubrange(i...(i + 1))
    return .id(id)
  }
  args.remove(at: i)
  if let candidate, args.count > positionals { usageDie("invalid workspace id: \(candidate)") }
  return .active
}

/// `pane list` / `tab new` の `--workspace <id>`（値必須）を抜き取る。フラグ自体が無ければ nil。
/// この 2 つが `--workspace` を取る唯一の pane / tab コマンドで、他は残余として usage エラーになる。
/// bare（値なし）も解決できない値も usage エラー——bare を黙ってアクティブ扱いにすると、
/// 絞り込みも開く先も指定と無関係に決まる。
func takeWorkspaceId(_ args: inout [String]) -> Int? {
  guard let i = args.firstIndex(of: "--workspace") else { return nil }
  guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
    usageDie("--workspace requires an <id>")
  }
  let token = args[i + 1]
  guard let id = workspaceIdIfResolvable(token) else { usageDie("invalid workspace id: \(token)") }
  args.removeSubrange(i...(i + 1))
  return id
}

/// フラグを取り切った後の残余を検査する。**全サブコマンドがこの関数を通る。**
///
/// `positionals` はそのサブコマンドが持つ位置引数の席の数。これを超えて残ったトークンは
/// どの席にも座れなかった＝解釈されなかったので usage エラー。`dashOK` は先頭から何席まで
/// `-` 始まりを値として通すかで、該当するのは `config set <key> <value>` の `<value>` だけ
/// （`config set font-size -1`。`<key>` の席は呼び出し側が別途弾く）。ws / pane / tab は id も
/// 名前もパスも `-` 始まりを取らないので `dashOK: 0`＝先頭から検査する。
///
/// 残余に落ちる形は 2 通りある。フラグの抜き取り（`takeWorkspaceTarget` / `takeWorkspaceId` /
/// `takeOption`）は綴りが**完全一致**した 1 個目しか見ないので `--workspace=3`・`--dir=/x`
/// （= 区切り）・綴り誤り・2 個目の指定が落ち、フラグ名を書き忘れた値（`orb tab new /repo`）や
/// 席から溢れた位置引数（`orb pane close 5 6`）も落ちる。検査しないとどちらも黙って捨てられ、
/// exit 0 のまま**指定と違う対象**を触る——`tab new` はアクティブ WS の既定 cwd にタブが生え、
/// `ws new` は既定 root の workspace ができ、`pane list` は絞り込みが効かず全 WS のペインが出る。
/// `pane close` / `tab close` では指定と無関係な現ペイン・現タブが消える。いずれも終了コードにも
/// stdout にも stderr にも現れない。
func rejectLeftovers(_ args: [String], positionals: Int, dashOK: Int = 0) {
  if let flag = args.dropFirst(dashOK).first(where: { $0.hasPrefix("-") }) {
    usageDie("unknown option: \(flag)")
  }
  if args.count > positionals {
    usageDie("unexpected argument: \(args[positionals])")
  }
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

/// pane 位置引数（省略時 ORBE_PANE）を解決する。位置引数があれば数値化（不正は usage エラー）、
/// 無ければ現ペイン。どちらも無ければ nil（呼び出し側が `orb pane list` を促す誘導エラーへ）。
///
/// 位置引数が居るなら数値化に失敗した時点で usage エラー——`-h` のような非数値が黙って現ペイン
/// 既定へ逸れることは無い。ただし `-1` は `Int()` を通るので、`-` 始まりを弾くのは呼び出し側の
/// `rejectLeftovers(_:positionals:dashOK:)` の役割。
func resolvePaneArg(_ args: [String]) -> Int? {
  if let first = args.first {
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
    transportDie("no active workspace")
  }
  return id
}

// MARK: - config key 一覧（usage テキスト表示用。key の妥当性・値型は control の config_list を SSOT に引く）

/// `SettingsRegistry.all` の全 key。usage は socket 不達でも出す必要があるため config_list からは
/// 引けず、ここに写す。この一覧のドリフトは `testConfigHelpListsEveryRegistryKey` が
/// `config --help` の `KEYS:` 行と registry を突き合わせて落とす。`configSetUsage` の型内訳だけは
/// 手書きのままなので、registry に key を足したらそちらも足すこと。
let allConfigKeys = [
  "font-size", "background-opacity", "background-blur", "cursor-style-blink", "theme",
  "font-family", "tab-title-font-family", "emoji-font", "default-agent", "agent-state-icons",
  "dev-features", "worktree-dir",
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
    orb tab new [--workspace <id>] [--dir <path>] [--cmd "…"]
    orb tab close [<tab>]

  COMMON FLAGS:
    --json              machine-readable JSON output (read commands / errors)
    --workspace [<id>]  target a workspace (<id> or current). bare --workspace
                        means the active one and is config-only; pane list /
                        tab new require an explicit <id>. no other pane / tab
                        command takes it
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
    orb pane list [--workspace <id|current>] [--json]
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
    orb tab new [--workspace <id>] [--dir <path>] [--cmd "…"]
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
    background-blur, cursor-style-blink, dev-features   true/false/on/off/1/0
    theme (auto/light/dark), font-family, tab-title-font-family, emoji-font,
    default-agent, worktree-dir   string
    agent-state-icons   map (set it from the settings palette)
  --workspace <id> writes that workspace's override, bare --workspace the active
  one (default without the flag: global).
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

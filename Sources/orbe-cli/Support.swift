import Foundation

// orbe-cli の出力・終了・引数ヘルパと、全ドメインを束ねるトップ usage。main.swift（socket
// クライアント）・`Commands+<ドメイン>.swift`（サブコマンド）が共用する。
// 終了コードは 0 成功 / 2 usage エラー / 1 RPC・接続エラー / 124 待機の時間切れ /
// 3・4 は `agent prompt` の待ち・終了（Commands+Agent.swift）。
//
// 各ドメインの USAGE 行と usage テキストは `Commands+<ドメイン>.swift` が持ち、`topUsage` は
// それらを合成する——ドメインの説明文がそのドメインのファイルの中だけで完結するように。

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

/// 端末から取り出した生テキストをそのまま stdout へ出す（`print` と違い改行を足さない）。
/// 取得した端末テキストは整形済みの報告ではなく捕捉した中身なので、`orb pane text > snapshot.txt`
/// が画面をそのまま再現できる必要がある。
func writeRaw(_ text: String) {
  FileHandle.standardOutput.write(Data(text.utf8))
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

/// 同じ値必須フラグの複数指定を全部抜き取る（`orb wait --kind agent_state --kind pane_closed`）。
/// 値の席の規則は `takeOption` と同一（複製しない）。1 個目しか見ない `takeOption` を素で使うと
/// 2 個目が残余に落ちて `rejectLeftovers` の usage エラーになる。
func takeOptions(_ args: inout [String], _ name: String, requires label: String) -> [String] {
  var out: [String] = []
  while let value = takeOption(&args, name, requires: label) { out.append(value) }
  return out
}

/// 値必須の整数オプション。既定は正整数（`--timeout-ms <ms>`）で、`atLeast: 0` にすると 0 を通す
/// （`--after <seq>`）。下限未満・非数値は usage エラー。`-` 始まりは `takeOption` が先に落とす。
func takeIntOption(
  _ args: inout [String], _ name: String, requires label: String, atLeast minimum: Int = 1
) -> Int? {
  guard let raw = takeOption(&args, name, requires: label) else { return nil }
  guard let n = Int(raw), n >= minimum else { usageDie("\(name) requires \(label)") }
  return n
}

/// `--text` / `--stdin` はちょうど一方が必須（`pane send` / `agent prompt` が同じ規則で受ける）。
func requireTextSource(text: String?, useStdin: Bool, verb: String) {
  if text != nil && useStdin { usageDie("pass only one of --text / --stdin") }
  guard text != nil || useStdin else { usageDie("\(verb) requires --text or --stdin") }
}

/// `--stdin` の中身を読む。0 バイトだけを弾き空白は通す——`printf '%s' "$PROMPT" | … --stdin` の
/// 未設定は 0 バイトとして現れる一方、ファイルや heredoc の正当な中身が空白・改行だけであることは
/// あり得るから（`--text` は空白のみも弾く非対称は意図的）。
func readStdinText() -> String {
  let data = FileHandle.standardInput.readDataToEndOfFile()
  guard !data.isEmpty else { usageDie("--stdin got no input") }
  guard let decoded = String(data: data, encoding: .utf8) else {
    usageDie("--stdin is not valid UTF-8")
  }
  return decoded
}

/// 値を取らないフラグ（`--scrollback` / `--stdin`）の有無を抜き取る。
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
/// 3 態を持つ。値を省けるのは config 系だけで、他ドメインは `takeWorkspaceId` が `<id|current>`
/// 必須で扱う——この非対称は spec の表記（`docs/spec/control/cli.md`）に揃えたもの。
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

/// `pane list` / `tab new` / `agent spawn` / `agent resume` の `--workspace <id>`（値必須）を
/// 抜き取る。フラグ自体が無ければ nil。この 4 つが `--workspace` を取る唯一の pane / tab /
/// agent コマンドで、他は残余として usage エラーになる。bare（値なし）も解決できない値も usage
/// エラー——bare を黙ってアクティブ扱いにすると、絞り込みも開く先も指定と無関係に決まる。
///
/// 値の席の規則（`-` 始まり・空を取らない）は `takeOption` が唯一持つ（ここで二重実装しない）。
func takeWorkspaceId(_ args: inout [String]) -> Int? {
  guard let token = takeOption(&args, "--workspace", requires: "an <id>") else { return nil }
  guard let id = workspaceIdIfResolvable(token) else { usageDie("invalid workspace id: \(token)") }
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

// MARK: - usage テキスト（ドメインの USAGE 行は `Commands+<ドメイン>.swift` が持つ）

/// USAGE 行の並びを help 本文へ落とす（2 スペース字下げ）。ドメイン単体の usage と `topUsage` が
/// 同じ 1 つの配列を同じ体裁で組む。
func usageBlock(_ lines: [String]) -> String {
  lines.map { "  " + $0 }.joined(separator: "\n")
}

/// トップ help に載る全サーフェス。ドメインを 1 つ足すときに触るのは、そのドメインのファイルと、
/// ここの 1 語と、`main.swift` のルーティング 1 行の 3 箇所。
private let allUsageLines =
  configUsageLines + wsUsageLines + paneUsageLines + tabUsageLines + agentUsageLines
  + waitUsageLines

let topUsage = """
  orb — configure and control the running Orbe instance

  USAGE:
  \(usageBlock(allUsageLines))

  COMMON FLAGS:
    --json              machine-readable JSON output (read commands / errors)
    --workspace [<id>]  target a workspace. bare --workspace means the active
                        one and is config-only; every other command that takes
                        the flag requires an explicit <id|current>, and the
                        USAGE lines above show which ones do
    --dir <path>        root/working directory (see the USAGE lines above)
    --cmd "…"           command to run in the new tab (tab new)

  pane / tab default to the current pane via ORBE_PANE. Outside a Orbe pane,
  pass an explicit id (see: orb pane list). wait is not a pane command and never
  falls back to ORBE_PANE — omitting <pane> watches every pane.
  Resolves the target instance from ORBE_STATE_DIR / ORBE_SOCK. Run inside a
  Orbe pane, or the control socket must be reachable; otherwise exits non-zero.
  Every --json result carries seq, the event-history position at that moment;
  pass it to `orb wait --after` to catch events that happen right after.
  Exit codes: 0 success, 2 usage error, 1 RPC/connection error, 124 timed out
  (wait / agent prompt / agent spawn / agent resume), 3 agent prompt: agent is
  waiting for input, 4 agent prompt: agent session ended.
  """

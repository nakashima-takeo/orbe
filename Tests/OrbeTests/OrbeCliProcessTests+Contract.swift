import Foundation
import OrbePaths
import XCTest

@testable import Orbe

/// `orb` の契約——終了コード・`--json` の出力先・文脈解決（`ORBE_TAB` / `current`）・
/// `--workspace` の意味論——を型ごとの代表で固定する。ライフサイクル 1 本（`OrbeCliProcessTests`）が
/// 「全サブコマンドが通る」ことを見るのに対し、こちらは「破れ方」を見る。
///
/// 壊れると何が起きるか: 終了コードは AI とスクリプトが分岐に使う唯一の信号で、usage エラー（2）と
/// RPC エラー（1）が混ざると「引数を直せばよい」と「Orbe が拒否した」が区別できなくなる。
/// `--json` の出力先が stdout から逸れれば機械可読という前提ごと壊れる。`--workspace` が値を
/// 黙って捨てれば、指定したのと**違う** workspace の設定が書き換わる（非破壊な誤りではない）。
///
/// `--workspace` の意味論は config 系（3 態）と tab 系（`<id>` 必須）で異なり、
/// `docs/spec/control/cli.md` はこれを書き分けている。表面的な一貫性のために潰さない。
extension OrbeCliProcessTests {
  /// arrange の書き込みを叩き、失敗したら stderr ごと理由を出す（素の status 比較だと
  /// `("0") is not equal to ("1")` しか出ず、どの層への書き込みが落ちたのか分からない）。
  private func write(
    _ control: ControlProcess, _ args: [String], _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let outcome = control.orb(args, file: file, line: line)
    XCTAssertEqual(
      outcome.status, 0, "\(label) への書き込みが失敗した: \(outcome.stderr)", file: file, line: line)
  }

  private func json(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws
    -> [String: Any]
  {
    let data = try XCTUnwrap(text.data(using: .utf8), file: file, line: line)
    return try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any],
      "JSON オブジェクトとして読めない: \(text)", file: file, line: line)
  }

  // MARK: - 終了コード

  /// 引数だけで判る誤りは socket に触れる前に exit 2 で弾く（Orbe が起動していなくても同じ）。
  func testUsageErrorsAreRejectedBeforeTouchingTheSocket() {
    failure(
      ControlProcess.orbWithoutServer(["config", "get"]), code: 2,
      message: "config get requires <key>", "引数不足")
    failure(
      ControlProcess.orbWithoutServer(["tab", "close", "abc"]), code: 2,
      message: "invalid tab id: abc", "非数値 id")
    failure(
      ControlProcess.orbWithoutServer(["tab", "close"]), code: 2,
      message: "no tab in context", "ORBE_TAB 無しの tab 対象欠如")
    // 値の席が空いた形（`--key` はあるが値が無い）は別分岐。ここはフラグごと落ちた形を見る
    // ——通すと空 key を control へ送って exit 1 に化け、usage エラーと RPC エラーが混ざる。
    failure(
      ControlProcess.orbWithoutServer(["tab", "key", "5"]), code: 2,
      message: "tab key requires --key <key>", "--key 自体の欠如")
    // 落とすと「再開したつもりが素の spawn」になるので、引数不足は socket の手前で止める。
    failure(
      ControlProcess.orbWithoutServer(["agent", "resume", "codex"]), code: 2,
      message: "agent resume requires <agent> and <session-id>", "resume の引数不足")
  }

  /// `--text` の値に置かれた `-h` / `--help` を help と読まない。
  ///
  /// `tab send` と `agent prompt` は「任意のユーザーテキストを値に取る」サーフェスで（ここは前者で
  /// 代表する）、引数列全体を help 走査すると `--text -h` が**何も送らないまま exit 0** になる。`orb tab send --text "$X" && orb tab
  /// key --key enter` で `$X` がたまたま `-h` だと、送信ゼロのまま enter だけが押される——静かで、
  /// 終了コードにも現れない。値の席のダッシュは exit 2 で止まるのが正しい。
  func testHelpInAValueSlotIsNotTreatedAsHelp() {
    for value in ["-h", "--help"] {
      let outcome = ControlProcess.orbWithoutServer(["tab", "send", "5", "--text", value])
      XCTAssertEqual(
        outcome.status, 2,
        "`--text \(value)` が help に化けて exit \(outcome.status): \(outcome.stdout)")
      XCTAssertFalse(
        outcome.stdout.contains("orb tab — inspect"), "usage を出して成功扱いにしない")
    }
    // `--help` 自体は従来どおり出る（値の席を抜いた後に残っていれば help）。
    let help = ControlProcess.orbWithoutServer(["tab", "send", "--help"])
    XCTAssertEqual(help.status, 0, "tab send --help は exit 0: \(help.stderr)")
  }

  /// socket 不達（Orbe 未起動・タブ外）はクラッシュせず exit 1 と構造化メッセージ。
  /// `--json` ではそれも stdout の `{"error":{code,message}}` に載る。
  func testUnreachableSocketExitsOneWithStructuredMessage() throws {
    let missing = TestIsolation.root.appendingPathComponent("no-orbe-here").path
    let plain = ControlProcess.orbWithoutServer(
      ["ws", "list"], env: [OrbePaths.stateDirEnvVar: missing])
    failure(plain, code: 1, message: "Orbe not running (cannot connect", "socket 不達")

    let structured = ControlProcess.orbWithoutServer(
      ["ws", "list", "--json"], env: [OrbePaths.stateDirEnvVar: missing])
    XCTAssertEqual(structured.status, 1, "--json でも終了コードは 1")
    let error = try XCTUnwrap(
      try json(structured.stdout)["error"] as? [String: Any], "--json は error を stdout へ載せる")
    XCTAssertEqual(error["code"] as? Int, -1, "接続エラーの code は -1（RPC の code と衝突しない）")
  }

  // MARK: - --json

  /// `--json` は成功もエラーも **stdout** へ出し、非 `--json` のエラーは stderr へ出す。
  /// フラグはどこに何度現れても位置引数として扱われない（共通フラグの契約）。
  func testJsonFlagRoutesOutputToStdoutAndIsPositionIndependent() throws {
    let control = try startControlProcess()

    let ok = control.orb(["ws", "list", "--json"])
    XCTAssertEqual(ok.status, 0, "read の成功は exit 0")
    XCTAssertNotNil(try json(ok.stdout)["workspaces"], "成功時の生 JSON は stdout へ")
    XCTAssertTrue(ok.stderr.isEmpty, "成功時に stderr へは何も出さない: \(ok.stderr)")

    let plain = control.orb(["ws", "switch", "999999"])
    failure(plain, code: 1, message: "error -32004", "RPC エラー")
    XCTAssertTrue(plain.stdout.isEmpty, "非 --json のエラーは stdout を汚さない: \(plain.stdout)")

    let structured = control.orb(["ws", "switch", "999999", "--json"])
    XCTAssertEqual(structured.status, 1, "--json でも RPC エラーは exit 1")
    let error = try XCTUnwrap(try json(structured.stdout)["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? Int, -32004, "control の code をそのまま載せる")
    XCTAssertTrue(structured.stderr.isEmpty, "--json のエラーは stderr へ二重に出さない: \(structured.stderr)")

    // `orb --json` を包んだラッパ越しに利用者がもう一度 `--json` を打つ形。1 個目しか抜かないと
    // 2 個目が位置引数に落ちてサブコマンド名として解釈される。
    let repeated = control.orb(["--json", "--json", "ws", "list"])
    XCTAssertEqual(
      repeated.status, 0, "--json が何度現れても位置引数にならない: \(repeated.stderr)")
    XCTAssertNotNil(try json(repeated.stdout)["workspaces"], "多重指定でも生 JSON が出る")
  }

  // MARK: - config key の妥当性

  /// 未知 key は `config_list` を SSOT に **set / unset の両方**が exit 2 で弾く。
  /// 片方だけ弾くと、打ち間違えた `unset` が「成功した」と表示されて上書きが残る。
  func testUnknownConfigKeyIsRejectedBySetAndUnset() throws {
    let control = try startControlProcess()
    failure(
      control.orb(["config", "set", "nosuch", "1"]), code: 2,
      message: "unknown config key: nosuch", "config set の未知 key")
    failure(
      control.orb(["config", "unset", "nosuch"]), code: 2,
      message: "unknown config key: nosuch", "config unset の未知 key")
  }

  // MARK: - --workspace

  /// config 系の `--workspace` は 3 態: 無指定＝global、bare＝アクティブ WS、`<id>`＝その WS。
  /// 書き込み先が 3 つ実在するので、3 つとも別の層へ落ちることを読み戻して確かめる。
  func testWorkspaceFlagHasThreeStatesForConfig() throws {
    let control = try startControlProcess()
    let backgroundId = try workspaceId(control, active: false)

    write(control, ["config", "set", "font-size", "20"], "global 層")
    write(control, ["config", "set", "font-size", "21", "--workspace"], "bare＝アクティブ WS 層")
    write(
      control, ["config", "set", "font-size", "22", "--workspace", "\(backgroundId)"], "背景 WS 層")

    let active = control.orbJSON(["config", "get", "font-size"])
    XCTAssertEqual(active["value"] as? Int, 21, "bare --workspace はアクティブ WS の上書きへ書く")
    XCTAssertEqual(active["scope"] as? String, "workspace", "bare で書いた値の層は workspace")
    let background = control.orbJSON(
      ["config", "get", "font-size", "--workspace", "\(backgroundId)"])
    XCTAssertEqual(background["value"] as? Int, 22, "--workspace <id> は非アクティブ WS へも書ける")

    // bare --workspace の unset でアクティブ側の上書きだけが外れ、global 明示値が現れる。
    write(control, ["config", "unset", "font-size", "--workspace"], "アクティブ WS 層の解除")
    let unwound = control.orbJSON(["config", "get", "font-size"])
    XCTAssertEqual(unwound["value"] as? Int, 20, "フラグ無しの set は global 層へ書かれていた")
    XCTAssertEqual(unwound["scope"] as? String, "global")
    XCTAssertEqual(
      control.orbJSON(["config", "get", "font-size", "--workspace", "\(backgroundId)"])["value"]
        as? Int, 22, "別 WS の上書きは巻き添えにならない")
  }

  /// config の bare `--workspace` は位置引数の**前**に置いても bare のまま——直後のトークンは
  /// `<key>` であって「解決できない `<id>`」ではない。この判別はフラグを外した残余が位置引数の数を
  /// 超えるかで行うので、境界が 1 つずれると `orb config set --workspace <key> <value>` が丸ごと
  /// usage エラーに化ける（bare を後置形だけで測っていると、この化け方は緑のまま素通りする）。
  ///
  /// `--workspace current` も同じ関数の解決経路で、こちらは `<id>` として消費される。
  func testBareWorkspaceFlagKeepsItsMeaningBeforeThePositionals() throws {
    let control = try startControlProcess()

    write(
      control, ["config", "set", "--workspace", "font-size", "23"],
      "前置の bare --workspace（<key> <value> が位置引数として残る）")
    XCTAssertEqual(
      control.orbJSON(["config", "get", "--workspace", "font-size"])["value"] as? Int, 23,
      "前置の bare --workspace の get が <key> を食い違えない")
    XCTAssertEqual(
      control.orbJSON(["config", "get", "font-size", "--workspace", "current"])["value"] as? Int,
      23, "--workspace current はアクティブ WS の <id> へ解決する（bare と同じ層を指す）")
    write(
      control, ["config", "unset", "--workspace", "font-size"],
      "前置の bare --workspace の unset（<key> が残る）")
    XCTAssertNotEqual(
      control.orbJSON(["config", "get", "font-size"])["value"] as? Int, 23,
      "その unset はアクティブ WS の上書きを実際に外す")
  }

  /// tab 系の `--workspace` は `<id>` 必須（「どれに絞るか・どこに開くか」で bare に割り当てる
  /// 意味が無い）。値が解決できないトークンは、フラグの前後どちらに位置引数が来ても同じ usage
  /// エラーにする——順序で「key に落ちて弾かれる」と「黙って無視してアクティブ WS へ書く」に
  /// 割れると、後者は指定と違う workspace を書き換える破壊的な誤りになる。
  func testWorkspaceFlagIsStrictWhereSpecRequiresAnId() throws {
    let control = try startControlProcess()

    failure(
      control.orb(["tab", "list", "--workspace"]), code: 2,
      message: "--workspace requires an <id>", "tab list の bare --workspace")
    failure(
      control.orb(["tab", "new", "--workspace"]), code: 2,
      message: "--workspace requires an <id>", "tab new の bare --workspace")
    failure(
      control.orb(["tab", "list", "--workspace", "nosuch"]), code: 2,
      message: "invalid workspace id: nosuch", "tab list の非解決トークン")
    failure(
      control.orb(["config", "set", "font-size", "14", "--workspace", "nosuch"]), code: 2,
      message: "invalid workspace id: nosuch", "値が後置された非解決トークン")
    failure(
      control.orb(["config", "set", "--workspace", "nosuch", "font-size", "14"]), code: 2,
      message: "invalid workspace id: nosuch", "値が前置された非解決トークン")
    // config の read / unset も同じ厳しさで揃える。黙ってアクティブ WS へ落ちると、`list` / `get` は
    // 指定と違う層を読み、`unset` は**指定と違う workspace の上書きを実際に外す**。
    failure(
      control.orb(["config", "list", "--workspace", "nosuch"]), code: 2,
      message: "invalid workspace id: nosuch", "config list の非解決トークン")
    failure(
      control.orb(["config", "get", "font-size", "--workspace", "nosuch"]), code: 2,
      message: "invalid workspace id: nosuch", "config get の非解決トークン")
    failure(
      control.orb(["config", "unset", "font-size", "--workspace", "nosuch"]), code: 2,
      message: "invalid workspace id: nosuch", "config unset の非解決トークン")

    // 正しい `<id>` 指定は通り、その workspace のタブだけに絞られる。
    let activeId = try workspaceId(control, active: true)
    let tabs = try XCTUnwrap(
      control.orbJSON(["tab", "list", "--workspace", "\(activeId)"])["tabs"] as? [[String: Any]])
    XCTAssertFalse(tabs.isEmpty, "--workspace <id> の絞り込みで結果が消えない")
    XCTAssertTrue(
      tabs.allSatisfy { $0["workspaceId"] as? Int == activeId }, "指定した WS のタブだけが残る")
    XCTAssertEqual(
      (control.orbJSON(["tab", "list", "--workspace", "current"])["tabs"] as? [[String: Any]])?
        .count, tabs.count, "`current` も `<id>` として解決する（数値だけの受け付けに退行しない）")
  }

  /// `--json` の応答は control の result をそのまま出すので、成功応答の `seq`（その操作時点の履歴位置）が
  /// 出る。`tab list` は tabs を絞る例外だが、`seq` は control の値をそのまま保つ——CLI が組み直して
  /// 0 に化けると、`orb wait --after` に渡した先で「保持している履歴の全部を replay」の意味になり、
  /// 前ターンの done を掴む。
  func testJsonResultsCarryTheHistoryPosition() throws {
    let control = try startControlProcess()
    let tab = try XCTUnwrap(control.target.current.tabs.first, "タブが無い")
    let activeId = try workspaceId(control, active: true)

    let sent = try XCTUnwrap(
      control.orbJSON(["tab", "send", "\(tab.id)", "--text", "x"])["seq"] as? Int,
      "tab send --json は {ok, seq} をそのまま出す")
    control.target.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "codex", state: "idle"))

    let filtered = control.orbJSON(["tab", "list", "--workspace", "\(activeId)"])
    XCTAssertNotNil(filtered["tabs"] as? [[String: Any]], "前提: 絞った tabs")
    let listed = try XCTUnwrap(filtered["seq"] as? Int, "--workspace で絞っても seq を保つ")
    XCTAssertGreaterThan(listed, sent, "tab list の seq は報告の後の履歴位置（組み直しで 0 に化けていない）")
  }

  /// `tab new --workspace <id>` は**その** workspace にタブを開く。値が黙って捨てられると、
  /// exit 0 のまま指定と無関係なアクティブ WS にタブが生える——「開けたのに見当たらない」という
  /// 形で現れるので、終了コードでも stdout でも気づけない。
  func testTabNewOpensInTheNamedWorkspace() throws {
    let control = try startControlProcess()
    let backgroundId = try workspaceId(control, active: false)

    let tabId = try XCTUnwrap(
      control.orbJSON(["tab", "new", "--workspace", "\(backgroundId)"])["tabId"] as? Int,
      "tab new が tabId を返さない")

    let tabs = try XCTUnwrap(control.orbJSON(["tab", "list"])["tabs"] as? [[String: Any]])
    XCTAssertEqual(
      tabs.first { $0["tabId"] as? Int == tabId }?["workspaceId"] as? Int, backgroundId,
      "開いたタブは指定した workspace に属する")
  }

  // MARK: - tab send の入力源

  /// `--stdin` で流した本文がタブへ届く。長いプロンプトを argv ではなくパイプで渡す経路。
  func testTabSendReadsTheBodyFromStdin() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(control.target.current.tabs.first, "タブが無い")
    let surface = tab.surface

    // シェルが rc を読み終える前に送ると tty の type-ahead に賭けることになる。プロンプトを待つ。
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        !(surface.controlReadText(scrollback: false) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }, "シェルのプロンプトが描かれない（この後の入力は捨てられうる）")

    let body = "STDIN_" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    let sent = control.orb(["tab", "send", "\(tab.id)", "--stdin"], stdin: body)
    XCTAssertEqual(sent.status, 0, "--stdin の送信が失敗した: \(sent.stderr)")
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        (surface.controlReadText(scrollback: true) ?? "").contains(body)
      }, "--stdin で流した本文がタブに現れない")
  }

  /// `tab send` の入力源は**ちょうど 1 つ**。両方も無指定も usage エラーで、無指定は標準入力に
  /// 触れずに落ちる——ここでハングしないことがこのテストの要点（`--stdin` を明示必須にした理由）。
  /// 0 バイトの `--stdin` も弾く: `printf '%s' "$PROMPT" | orb tab send --stdin` の未設定が
  /// その形で現れ、規約が守ろうとしている「値が黙って消えた」ものそのものだから。
  func testTabSendRequiresExactlyOneInputSource() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(control.target.current.tabs.first, "タブが無い")

    failure(
      control.orb(["tab", "send", "\(tab.id)", "--text", "hi", "--stdin"]), code: 2,
      message: "pass only one of --text / --stdin", "--text と --stdin の併用")
    // stdin を渡さない＝子の標準入力は /dev/null。読みに行く実装ならここで即 EOF を掴んで
    // 「0 バイト」に化けるので、文言まで見て「触れずに落ちた」ことを確かめる。
    failure(
      control.orb(["tab", "send", "\(tab.id)"]), code: 2,
      message: "tab send requires --text or --stdin", "入力源の無指定")
    failure(
      control.orb(["tab", "send", "\(tab.id)", "--stdin"], stdin: ""), code: 2,
      message: "--stdin got no input", "0 バイトの --stdin")

    // 空白・改行だけの入力は通す（ファイルや heredoc の正当な中身でありうる）。
    let whitespace = control.orb(["tab", "send", "\(tab.id)", "--stdin"], stdin: "  \n")
    XCTAssertEqual(whitespace.status, 0, "空白だけの --stdin は通す: \(whitespace.stderr)")
  }

  // MARK: - 文脈解決

  /// tab 系の対象は `ORBE_TAB` を既定に取り、`<id|current>` の `current` はアクティブ WS へ解決する。
  func testTabAndWorkspaceTargetsResolveFromContext() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(control.target.current.tabs.first)
    let sent = control.orb(["tab", "send", "--text", "x"], env: ["ORBE_TAB": "\(tab.id)"])
    XCTAssertEqual(sent.status, 0, "ORBE_TAB があれば位置引数なしで送れる: \(sent.stderr)")
    XCTAssertEqual(sent.stdout, "sent to tab \(tab.id)\n", "送信の宛先は ORBE_TAB のタブ")

    write(control, ["ws", "rename", "current", "l4-current"], "current 宛ての ws rename")
    XCTAssertEqual(
      try workspaceRows(control).first(where: { $0["active"] as? Bool == true })?["name"]
        as? String, "l4-current", "current はアクティブ WS へ解決する")
  }

  /// `tab focus` は `<tab>` 省略時に **ORBE_TAB を継がない**——自タブへの focus は無意味で、
  /// 継ぐと「id を書き忘れた」誤りが exit 0 の no-op に化ける。`wait` / `agent prompt` と同じ規律。
  func testTabFocusDoesNotFallBackToOrbeTab() {
    failure(
      ControlProcess.orbWithoutServer(["tab", "focus"], env: ["ORBE_TAB": "1"]), code: 2,
      message: "tab focus requires a <tab> id", "ORBE_TAB 付きの `tab focus`")
  }

  /// 不明コマンドは socket の手前で exit 2 ＋ `unknown command: <token>`。通すと control へ届いて
  /// exit 1（RPC エラー）に化け、usage エラーと区別がつかなくなる。標本の語は同時に
  /// 「`orb tab` の別名として受理しない」ことも押さえる——2 つの語彙が同じ操作を指すと、
  /// ヘルプと補完がどちらを教えるか割れる。
  func testUnknownCommandExitsTwo() {
    failure(
      ControlProcess.orbWithoutServer(["pane", "list"]), code: 2,
      message: "unknown command: pane", "`orb pane`")
  }
}

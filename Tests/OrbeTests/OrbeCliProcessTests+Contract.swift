import Foundation
import OrbePaths
import XCTest

@testable import Orbe

/// `orb` の契約——終了コード・`--json` の出力先・文脈解決（`ORBE_PANE` / `current`）・
/// `--workspace` の意味論——を型ごとの代表で固定する。ライフサイクル 1 本（`OrbeCliProcessTests`）が
/// 「全サブコマンドが通る」ことを見るのに対し、こちらは「破れ方」を見る。
///
/// 壊れると何が起きるか: 終了コードは AI とスクリプトが分岐に使う唯一の信号で、usage エラー（2）と
/// RPC エラー（1）が混ざると「引数を直せばよい」と「Orbe が拒否した」が区別できなくなる。
/// `--json` の出力先が stdout から逸れれば機械可読という前提ごと壊れる。`--workspace` が値を
/// 黙って捨てれば、指定したのと**違う** workspace の設定が書き換わる（非破壊な誤りではない）。
///
/// `--workspace` の意味論は config 系（3 態）と pane/tab（`<id>` 必須）で異なり、
/// `docs/spec/orbe-cli.md` はこれを書き分けている。表面的な一貫性のために潰さない。
extension OrbeCliProcessTests {
  private func failure(
    _ outcome: ControlProcess.Outcome, code: Int32, message: String, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      outcome.status, code,
      "\(label) は exit \(code): stdout=\(outcome.stdout) stderr=\(outcome.stderr)",
      file: file, line: line)
    XCTAssertTrue(
      outcome.stderr.contains(message),
      "\(label) の stderr に \"\(message)\" が無い: \(outcome.stderr)", file: file, line: line)
  }

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
      ControlProcess.orbWithoutServer(["pane", "close", "abc"]), code: 2,
      message: "invalid pane id: abc", "非数値 id")
    failure(
      ControlProcess.orbWithoutServer(["pane", "close"]), code: 2,
      message: "no pane in context", "ORBE_PANE 無しの pane 対象欠如")
  }

  /// socket 不達（Orbe 未起動・ペイン外）はクラッシュせず exit 1 と構造化メッセージ。
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

  /// pane/tab の `--workspace` は `<id>` 必須（「どれに絞るか・どこに開くか」で bare に割り当てる
  /// 意味が無い）。値が解決できないトークンは、フラグの前後どちらに位置引数が来ても同じ usage
  /// エラーにする——順序で「key に落ちて弾かれる」と「黙って無視してアクティブ WS へ書く」に
  /// 割れると、後者は指定と違う workspace を書き換える破壊的な誤りになる。
  func testWorkspaceFlagIsStrictWhereSpecRequiresAnId() throws {
    let control = try startControlProcess()

    failure(
      control.orb(["pane", "list", "--workspace"]), code: 2,
      message: "--workspace requires an <id>", "pane list の bare --workspace")
    failure(
      control.orb(["tab", "new", "--workspace"]), code: 2,
      message: "--workspace requires an <id>", "tab new の bare --workspace")
    failure(
      control.orb(["pane", "list", "--workspace", "nosuch"]), code: 2,
      message: "invalid workspace id: nosuch", "pane list の非解決トークン")
    failure(
      control.orb(["config", "set", "font-size", "14", "--workspace", "nosuch"]), code: 2,
      message: "invalid workspace id: nosuch", "値が後置された非解決トークン")
    failure(
      control.orb(["config", "set", "--workspace", "nosuch", "font-size", "14"]), code: 2,
      message: "invalid workspace id: nosuch", "値が前置された非解決トークン")

    // 正しい `<id>` 指定は通り、その workspace のペインだけに絞られる。
    let activeId = try workspaceId(control, active: true)
    let panes = try XCTUnwrap(
      control.orbJSON(["pane", "list", "--workspace", "\(activeId)"])["panes"] as? [[String: Any]])
    XCTAssertFalse(panes.isEmpty, "--workspace <id> の絞り込みで結果が消えない")
    XCTAssertTrue(
      panes.allSatisfy { $0["workspaceId"] as? Int == activeId }, "指定した WS のペインだけが残る")
    XCTAssertEqual(
      (control.orbJSON(["pane", "list", "--workspace", "current"])["panes"] as? [[String: Any]])?
        .count, panes.count, "`current` も `<id>` として解決する（数値だけの受け付けに退行しない）")
  }

  /// `--workspace` の抜き取りは綴りが**完全一致**した 1 個目しか見ないので、`--workspace=3`（= 区切り）・
  /// 綴り誤り・2 個目の指定は残余トークンに落ちる。残余を検査しないとそれらは黙って捨てられ、
  /// exit 0 のまま**指定と違う workspace** を触る——`tab new` はアクティブ WS にタブが生え、
  /// `pane list` は絞り込みが効かず全 WS のペインが出る。終了コードにも stdout にも現れない。
  ///
  /// `-` 始まりでも**位置引数の席**なら値なので通す（`config set font-size -1` の `-1`）。この境界を
  /// 「残余に `-` があれば一律エラー」に広げると、負の値がすべて usage エラーに化ける。
  func testUnconsumedFlagLikeTokensAreRejectedInsteadOfSilentlyDropped() throws {
    let control = try startControlProcess()

    for args in [
      ["tab", "new", "--workspace=3"],
      ["pane", "list", "--workspace=3"],
      ["pane", "list", "--workspce", "3"],
      ["config", "set", "theme", "dark", "--workspace", "-1"],
      ["config", "set", "font-size", "14", "--workspace", "current", "--workspace", "nosuch"],
    ] {
      failure(
        control.orb(args), code: 2, message: "unknown option:",
        "解釈されなかった `\(args.joined(separator: " "))`")
    }

    // 位置引数の席に来た `-` 始まりは値として解析を通る（弾きすぎの防止）。値域を見るのはサーバなので、
    // ここで確かめるのは「未知フラグとして前段で落とされない」ことだけ。
    let negative = control.orb(["config", "set", "font-size", "-1"])
    XCTAssertFalse(
      negative.stderr.contains("unknown option"),
      "位置引数の席の `-1` を未知フラグとして弾いている: \(negative.stderr)")
  }

  /// `tab new --workspace <id>` は**その** workspace にタブを開く。値が黙って捨てられると、
  /// exit 0 のまま指定と無関係なアクティブ WS にタブが生える——「開けたのに見当たらない」という
  /// 形で現れるので、終了コードでも stdout でも気づけない。
  func testTabNewOpensInTheNamedWorkspace() throws {
    let control = try startControlProcess()
    let backgroundId = try workspaceId(control, active: false)

    let paneId = try XCTUnwrap(
      control.orbJSON(["tab", "new", "--workspace", "\(backgroundId)"])["paneId"] as? Int,
      "tab new が paneId を返さない")

    let panes = try XCTUnwrap(control.orbJSON(["pane", "list"])["panes"] as? [[String: Any]])
    XCTAssertEqual(
      panes.first { $0["paneId"] as? Int == paneId }?["workspaceId"] as? Int, backgroundId,
      "開いたタブは指定した workspace に属する")
  }

  // MARK: - 文脈解決

  /// pane 系の対象は `ORBE_PANE` を既定に取り、`<id|current>` の `current` はアクティブ WS へ解決する。
  func testPaneAndWorkspaceTargetsResolveFromContext() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(control.target.current.tabs.first)
    let pane = try XCTUnwrap(tab.controlAllPanes().first)

    let split = control.orb(["pane", "split"], env: ["ORBE_PANE": "\(pane.id)"])
    XCTAssertEqual(split.status, 0, "ORBE_PANE があれば位置引数なしで split できる: \(split.stderr)")
    XCTAssertEqual(tab.controlAllPanes().count, 2, "分割の宛先は ORBE_PANE のペイン")

    write(control, ["ws", "rename", "current", "l4-current"], "current 宛ての ws rename")
    XCTAssertEqual(
      try workspaceRows(control).first(where: { $0["active"] as? Bool == true })?["name"]
        as? String, "l4-current", "current はアクティブ WS へ解決する")
  }
}

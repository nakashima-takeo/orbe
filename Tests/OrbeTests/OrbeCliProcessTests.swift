import XCTest

@testable import Orbe

/// 実 `orb`（`orbe-cli`）を子プロセスで起こし、全 16 サブコマンドが実 `WindowController` を
/// 1 本のライフサイクルとして動かせることを固定する。
///
/// 16 本に割らず 1 本に束ねているのは、`ws new → rename → dir → switch → rm` のように後段が前段の
/// 状態を前提にする連鎖だから。割ると各テストが同じ fixture を組み直すことになり、測っている
/// ライフサイクルの形が崩れる。割って得られるはずの「どこで落ちたか」の解像度は assert メッセージに
/// サブコマンド名を載せることで代替する（連鎖の途中で落ちると以降が見えないので、メッセージだけで
/// どの段かが分かる必要がある）。
///
/// 壊れると何が起きるか: CLI が組み立てる control メソッド名の綴りは、どのテストにも現れない。
/// 片方だけ改名すれば `-32601` で全滅するが、それに気づく経路がこの 1 本しかない。
/// workspace / pane の id は `IdGen` 採番で予測不能なので、必ず `--json` の出力から読む。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続する（GhosttyKit 必須）。純ロジック検証ではない。
final class OrbeCliProcessTests: OrbeTestCase {
  /// 1 段を叩き、exit 0 と stdout の要点を確かめる。
  @discardableResult
  private func step(
    _ control: ControlProcess, _ args: [String], expect fragment: String,
    env: [String: String] = [:], file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let label = "orb " + args.joined(separator: " ")
    let outcome = control.orb(args, env: env, file: file, line: line)
    XCTAssertEqual(
      outcome.status, 0, "\(label) が exit 0 でない: \(outcome.stderr)", file: file, line: line)
    XCTAssertTrue(
      outcome.stdout.contains(fragment),
      "\(label) の stdout に \"\(fragment)\" が無い: \(outcome.stdout)", file: file, line: line)
    return outcome.stdout
  }

  /// 落ちた 1 段の終了コードと stderr を一緒に見る。`private` を付けない——同じ型の extension でも
  /// 別ファイル（`+Contract` / `+Rejection`）からは見えなくなり、同じ判定がそちらへ複製される。
  func failure(
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

  /// L3 の `ControlWireTests` の `startWire` / `errorCode` と同じ形で、問い合わせも共有する。
  func workspaceRows(_ control: ControlProcess) throws -> [[String: Any]] {
    try XCTUnwrap(control.orbJSON(["ws", "list"])["workspaces"] as? [[String: Any]])
  }

  /// `ws list` から `active` が一致する行の id を引く（id は `IdGen` 採番で予測不能なので必ず出力から読む）。
  func workspaceId(_ control: ControlProcess, active: Bool) throws -> Int {
    try XCTUnwrap(
      workspaceRows(control).first(where: { $0["active"] as? Bool == active })?["id"] as? Int,
      active ? "アクティブ WS が無い" : "背景 WS が無い")
  }

  func configValue(_ control: ControlProcess, _ key: String, args: [String] = []) -> Any? {
    control.orbJSON(["config", "get", key] + args)["value"]
  }

  /// 全 16 サブコマンドを 1 つの実 `WindowController` に対して順に叩く。
  /// `ws rm` を最後に置くのは「最後の 1 つは削除不可（-32000）」を踏まないため。
  func testEverySubcommandDrivesOneLifecycle() throws {
    let control = try startControlProcess(workspaces: ["main"])

    // --- ws（6）: list → new → rename → dir → switch → （rm は最後）
    let before = try workspaceRows(control)
    let mainId = try XCTUnwrap(
      before.first(where: { $0["active"] as? Bool == true })?["id"] as? Int, "ws list: アクティブ WS が無い"
    )

    // `--dir` を通す正常系。これが無いと、門番を `--dir` の抜き取りより前へ動かして
    // `--dir` を丸ごと使えなくする変更が、拒否ケースだけのテストをすり抜ける。
    // 実在ディレクトリを渡す——`createWorkspace` は rootPath を initialCwd に実シェルを起こす。
    let created = control.orbJSON(["ws", "new", "scratch", "--dir", "/tmp"])
    let scratchId = try XCTUnwrap(created["workspaceId"] as? Int, "ws new: workspaceId を返さない")
    XCTAssertEqual(created["name"] as? String, "scratch", "ws new: 指定した名前で作られる")
    XCTAssertEqual(
      created["rootPath"] as? String, "/tmp", "ws new: --dir <path> が rootPath として効く")

    step(control, ["ws", "rename", "\(scratchId)", "renamed"], expect: "renamed workspace")
    step(control, ["ws", "dir", "\(scratchId)", "/tmp/l4-root"], expect: "set workspace")
    // ws new は作成と同時にアクティブ化するため、ここは冪等 activate ではない実際の切り替えになる。
    step(control, ["ws", "switch", "\(mainId)"], expect: "switched to workspace \(mainId)")

    let afterSwitch = try workspaceRows(control)
    XCTAssertEqual(
      afterSwitch.first(where: { $0["active"] as? Bool == true })?["id"] as? Int, mainId,
      "ws switch: 指定した WS が実際にアクティブになる")
    XCTAssertEqual(
      afterSwitch.first(where: { $0["id"] as? Int == scratchId })?["name"] as? String, "renamed",
      "ws rename: 改名が一覧に反映される")
    XCTAssertEqual(
      afterSwitch.first(where: { $0["id"] as? Int == scratchId })?["rootPath"] as? String,
      "/tmp/l4-root", "ws dir: rootPath の変更が一覧に反映される")

    // --- config（4）: list → set → get → unset
    step(control, ["config", "list"], expect: "font-size")
    step(control, ["config", "set", "font-size", "17"], expect: "ok: font-size = 17 [global]")
    XCTAssertEqual(configValue(control, "font-size") as? Int, 17, "config get: set した値が読める")
    step(control, ["config", "unset", "font-size"], expect: "unset: font-size [global]")
    XCTAssertNotEqual(
      configValue(control, "font-size") as? Int, 17, "config unset: 明示値が外れて既定へ戻る")

    // --- pane / tab（6）: pane list → tab new → pane split → pane focus → pane close → tab close
    let panesBefore = try XCTUnwrap(
      control.orbJSON(["pane", "list"])["panes"] as? [[String: Any]], "pane list: panes を返さない")
    XCTAssertFalse(panesBefore.isEmpty, "pane list: アクティブ WS のペインが 1 つも出ない")

    let opened = control.orbJSON(["tab", "new", "--dir", "/tmp"])
    let openedPane = try XCTUnwrap(opened["paneId"] as? Int, "tab new: paneId を返さない")
    let split = control.orbJSON(["pane", "split", "\(openedPane)"])
    let splitPane = try XCTUnwrap(split["paneId"] as? Int, "pane split: 新ペイン id を返さない")

    step(control, ["pane", "focus", "\(splitPane)"], expect: "focused pane \(splitPane)")
    step(control, ["pane", "close", "\(splitPane)"], expect: "closed pane \(splitPane)")
    // tab close は位置引数を省くと ORBE_PANE の所属タブを list_panes 走査で解決する。
    step(
      control, ["tab", "close"], expect: "closed tab",
      env: ["ORBE_PANE": "\(openedPane)"])

    let panesAfter = try XCTUnwrap(control.orbJSON(["pane", "list"])["panes"] as? [[String: Any]])
    XCTAssertFalse(
      panesAfter.contains { $0["paneId"] as? Int == openedPane },
      "tab close: 開いたタブのペインが消える")

    // --- ws rm（16 本目）
    step(control, ["ws", "rm", "\(scratchId)"], expect: "removed workspace \(scratchId)")
    XCTAssertFalse(
      try workspaceRows(control).contains { $0["id"] as? Int == scratchId },
      "ws rm: 削除した WS が一覧から消える")
  }

  /// ペインのシェルで bare `orb` が**同梱** CLI へ解決し、走った先がこのインスタンスの自ペインになる。
  ///
  /// 2 つを別々に測る。前半は `PATH` 前置そのもの——ペインの実 env で `command -v orb` を引き、
  /// 同梱 `bin/orb` に解決することを見る。ペイン内の効果だけでは前置は測れない: 開発機の PATH には
  /// 別インスタンスの `orb` が居ることがあり、しかもペインは `ORBE_STATE_DIR` を継承するので、
  /// **どの** `orb` が走ってもこのインスタンスの socket へ届いて後半が通ってしまう。
  ///
  /// 後半は注入された `ORBE_PANE` と socket 到達——`pane split` は位置引数を省くと `ORBE_PANE` を
  /// 宛先にするので、ペインが 2 枚になったこと自体がその 2 つを同時に示す。観測をレイアウトの実変化で
  /// 取るのは、ペインのテキストがプロンプトのテーマや rc に依るため。
  func testBareOrbResolvesToBundledCliInsidePane() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(control.target.current.tabs.first, "タブが無い")
    let pane = try XCTUnwrap(tab.controlAllPanes().first, "ペインが無い")
    XCTAssertEqual(tab.controlAllPanes().count, 1, "前提: 分割前は 1 ペイン")

    // PATH 前置の解決先そのもの。`PATH` に種を置くのは、前置が空なら親プロセスの PATH を読むため。
    var env = ["PATH": "/usr/bin:/bin"]
    pane.injectRuntimeEnv(to: &env)
    let resolved = ControlProcess.run(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "command -v orb"], env: env)
    let bundled = try XCTUnwrap(BundledResources.root, "同梱物がステージされていない")
      .appendingPathComponent("bin/orb").path
    XCTAssertEqual(
      resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines), bundled,
      "ペインの PATH 先頭が同梱 orb へ解決しない（前置が外れると別インスタンスの orb に落ちる）")

    // シェルが rc を読み終える前に送ると tty の type-ahead に賭けることになり、失われた入力は
    // `controlSendText` の無言 no-op として誰も報告しない。プロンプトが描かれてから送る。
    XCTAssertTrue(
      waitUntil(ControlProcess.paneSettleTimeout) {
        !(pane.controlReadText(scrollback: false) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }, "シェルのプロンプトが描かれない（この後の入力は捨てられうる）")

    pane.controlSendText("orb pane split")
    pane.controlSendKey(try XCTUnwrap(ControlKey.parse("enter")))

    XCTAssertTrue(
      waitUntil(ControlProcess.paneSettleTimeout) { tab.controlAllPanes().count == 2 },
      "bare `orb` がペイン内で解決していない: \(pane.controlReadText(scrollback: true) ?? "")")
  }
}

import Foundation
import OrbeSessionLog
import XCTest

@testable import Orbe

/// 実 `orb`（`orbe-cli`）を子プロセスで起こし、全 25 サブコマンドのうち 22 が実 `WindowController`
/// を 1 本のライフサイクルとして動かせることを固定する。残る `agent spawn` / `agent resume` は
/// 検出の仕込み（偽実行体と `ShellPATH` の差し替え）が要るので `OrbeCliAgentProcessTests` が、
/// `agent prompt` は `OrbeCliAgentPromptProcessTests` が持つ。
///
/// 1 本に束ねているのは、`ws new → rename → dir → switch → rm` のように後段が前段の
/// 状態を前提にする連鎖だから。割ると各テストが同じ fixture を組み直すことになり、測っている
/// ライフサイクルの形が崩れる。割って得られるはずの「どこで落ちたか」の解像度は assert メッセージに
/// サブコマンド名を載せることで代替する（連鎖の途中で落ちると以降が見えないので、メッセージだけで
/// どの段かが分かる必要がある）。
///
/// 壊れると何が起きるか: CLI が組み立てる control メソッド名の綴りは、どのテストにも現れない。
/// 片方だけ改名すれば `-32601` で全滅するが、それに気づく経路がこの 1 本しかない。
/// workspace / tab の id は `IdGen` 採番で予測不能なので、必ず `--json` の出力から読む。
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

  /// ws の 5 本（list → new → rename → dir → switch。rm はライフサイクルの最後）を叩き、
  /// 作った workspace の id を返す。連鎖の一部なのでライフサイクル本体と同じ `control` に対して走る。
  private func driveWorkspaceSubcommands(_ control: ControlProcess) throws -> Int {
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
    return scratchId
  }

  /// 22 サブコマンドを 1 つの実 `WindowController` に対して順に叩く。
  /// `ws rm` を最後に置くのは「最後の 1 つは削除不可（-32000）」を踏まないため。
  func testEverySubcommandDrivesOneLifecycle() throws {
    let control = try startControlProcess(workspaces: ["main"])

    // --- ws（6）: list → new → rename → dir → switch → （rm は最後）
    let scratchId = try driveWorkspaceSubcommands(control)

    // --- config（4）: list → set → get → unset
    step(control, ["config", "list"], expect: "font-size")
    step(control, ["config", "set", "font-size", "17"], expect: "ok: font-size = 17 [global]")
    XCTAssertEqual(configValue(control, "font-size") as? Int, 17, "config get: set した値が読める")
    step(control, ["config", "unset", "font-size"], expect: "unset: font-size [global]")
    XCTAssertNotEqual(
      configValue(control, "font-size") as? Int, 17, "config unset: 明示値が外れて既定へ戻る")

    // --- agent list（1）: 検出ゼロでもエラーにしない（実際の検出結果には依らない）
    XCTAssertNotNil(
      control.orbJSON(["agent", "list"])["agents"] as? [[String: Any]],
      "agent list: agents を返さない（検出ゼロは空配列で成功）")

    // --- wait（1）: 何も起きなければ時間切れ（exit 124）。イベントで起きる側は専用ファイルが持つ。
    // 宛先に実在しないタブを置くのは、fixture のシェルが OSC 7 で撃つ `pwd` で起きないため。
    let waited = control.orb(["wait", "999999", "--timeout-ms", "200"])
    XCTAssertEqual(waited.status, 124, "wait: 時間切れは exit 124: \(waited.stderr)")

    // --- tab（7）: tab list → tab new → tab text/send/key → tab focus → tab close
    let tabsBefore = try XCTUnwrap(
      control.orbJSON(["tab", "list"])["tabs"] as? [[String: Any]], "tab list: tabs を返さない")
    XCTAssertFalse(tabsBefore.isEmpty, "tab list: アクティブ WS のタブが 1 つも出ない")

    let opened = control.orbJSON(["tab", "new", "--dir", "/tmp"])
    let openedTab = try XCTUnwrap(opened["tabId"] as? Int, "tab new: tabId を返さない")
    let second = control.orbJSON(["tab", "new", "--dir", "/tmp"])
    let secondTab = try XCTUnwrap(second["tabId"] as? Int, "tab new: 2 枚目の tabId を返さない")

    // tab text は生テキストを返す（`--json` なら text キー）。中身はシェルの rc 次第なので
    // ここで見るのは「読める形で返る」ことだけ——実際の描画内容は agent / mcp のテストが見る。
    XCTAssertNotNil(
      control.orbJSON(["tab", "text", "\(openedTab)"])["text"] as? String,
      "tab text: text を返さない")
    step(control, ["tab", "send", "\(openedTab)", "--text", "echo hi"], expect: "sent to tab")
    step(
      control, ["tab", "key", "\(openedTab)", "--key", "enter"],
      expect: "sent key enter to tab")

    step(control, ["tab", "focus", "\(openedTab)"], expect: "focused tab \(openedTab)")
    step(control, ["tab", "close", "\(secondTab)"], expect: "closed tab \(secondTab)")
    // 閉じる前に同一性（hook の報告）を載せる——`tab close` が寿命ログに closed(controlAPI) を残し、
    // 続く session の 3 本がそれを読む。報告は main で直接適用する（report_agent は orb に無い）。
    let openedTerminal = try XCTUnwrap(control.target.controlResolveTab(openedTab))
    control.target.controlReportAgent(
      tab: openedTerminal,
      report: AgentHookReport(agent: "claude", state: "idle", sessionId: "l4-sess-1"))
    // tab close は位置引数を省くと ORBE_TAB を宛先にする。
    step(
      control, ["tab", "close"], expect: "closed tab \(openedTab)",
      env: ["ORBE_TAB": "\(openedTab)"])

    let tabsAfter = try XCTUnwrap(control.orbJSON(["tab", "list"])["tabs"] as? [[String: Any]])
    XCTAssertFalse(
      tabsAfter.contains { $0["tabId"] as? Int == openedTab || $0["tabId"] as? Int == secondTab },
      "tab close: 開いたタブが消える")

    // --- session（3）: log → closed → restore
    try driveSessionSubcommands(control, sessionId: "l4-sess-1")

    // --- ws rm（22 本目）
    step(control, ["ws", "rm", "\(scratchId)"], expect: "removed workspace \(scratchId)")
    XCTAssertFalse(
      try workspaceRows(control).contains { $0["id"] as? Int == scratchId },
      "ws rm: 削除した WS が一覧から消える")
  }

  /// session の 3 本。閉じた同一性がログに残っていることを前提に、log → closed → restore。
  private func driveSessionSubcommands(_ control: ControlProcess, sessionId: String) throws {
    try driveSessionLog(control, sessionId: sessionId)
    try driveSessionClosedAndRestore(control, sessionId: sessionId)
  }

  private func sessionIds(_ result: [String: Any]) -> [String] {
    (result["events"] as? [[String: Any]] ?? []).compactMap {
      ($0["agent"] as? [String: Any])?["sessionId"] as? String
    }
  }

  /// `session log`: 2 行・`--limit` はファイル順の末尾を残して stderr で告げる・相対 `--since` の 3 単位・
  /// `--until`・`--session`。境界は 90 分前の opened を 1 行足して見る（サーバは in-process と同じファイルを読む）。
  private func driveSessionLog(_ control: ControlProcess, sessionId: String) throws {
    let log = try XCTUnwrap(control.orbJSON(["session", "log"])["events"] as? [[String: Any]])
    XCTAssertEqual(
      log.map { $0["event"] as? String }, ["opened", "closed"], "session log: opened → closed の 2 行"
    )
    XCTAssertEqual(
      log.last?["origin"] as? String, "controlAPI", "session log: tab close は controlAPI")
    let limited = control.orb(["session", "log", "--limit", "1", "--json"])
    XCTAssertEqual(limited.status, 0, limited.stderr)
    XCTAssertTrue(
      limited.stderr.contains("truncated"),
      "session log --limit: 落とした側を stderr で告げる: \(limited.stderr)")
    let limitedJSON = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(limited.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(
      (limitedJSON["events"] as? [[String: Any]])?.map { $0["event"] as? String }, ["closed"],
      "session log --limit 1: 新しい側の 1 件")
    XCTAssertEqual(limitedJSON["truncated"] as? Bool, true)

    let oldId = "l4-old-1"
    try SessionLogWriter.append(
      SessionEvent(
        ts: Date().addingTimeInterval(-90 * 60), kind: .opened,
        workspace: .init(name: "main", rootPath: "/tmp"), cwd: "/tmp",
        agent: .init(command: "claude", sessionId: oldId)),
      to: XCTUnwrap(AgentSessionLog.fileURL))
    let recent = step(control, ["session", "log", "--since", "30m"], expect: sessionId)
    XCTAssertTrue(recent.contains("\tcontrolAPI"), "session log: 人向けの行に origin が載る: \(recent)")
    XCTAssertFalse(recent.contains(oldId), "session log --since 30m: 90 分前の行は落ちる: \(recent)")
    for since in ["2h", "1d"] {
      step(control, ["session", "log", "--since", since], expect: oldId)
    }
    let hourAgo = SessionEvent.iso8601(Date().addingTimeInterval(-3600))
    XCTAssertEqual(
      sessionIds(control.orbJSON(["session", "log", "--until", hourAgo])), [oldId],
      "session log --until: 1 時間前までは 90 分前の 1 行だけ")
    XCTAssertEqual(
      sessionIds(control.orbJSON(["session", "log", "--session", "nope"])), [],
      "session log --session: 一致しない id は空")
  }

  /// `session closed` は新しい順の群（人向けの見出し・メンバー行・`--json` の `at`）、`session restore` は
  /// 位置引数と `--at` の両方で `restored`、再実行は already-present、未知 id は exit 1。2 群目は gesture で
  /// 閉じた同一性を in-process で作る。
  private func driveSessionClosedAndRestore(_ control: ControlProcess, sessionId: String) throws {
    let second = "l4-sess-2"
    let opened = try XCTUnwrap(control.target.openTab(workspaceIndex: 0, cwd: "/tmp"))
    let tab = try XCTUnwrap(control.target.controlResolveTab(opened.tabId))
    tab.applyReport(AgentHookReport(agent: "claude", state: "idle", sessionId: second))
    control.target.closeTab(tab, origin: .gesture)

    let human = step(control, ["session", "closed"], expect: "1 session closed (gesture)")
    XCTAssertTrue(
      human.contains("1 session closed (controlAPI)"), "session closed: 群ごとの見出し: \(human)")
    XCTAssertTrue(
      human.contains("\tclaude\t\(second)\tmain\t"), "session closed: メンバー行: \(human)")
    let groups = try XCTUnwrap(
      control.orbJSON(["session", "closed"])["groups"] as? [[String: Any]],
      "session closed: groups を返さない")
    XCTAssertEqual(
      groups.map { $0["origin"] as? String }, ["gesture", "controlAPI"], "session closed: 新しい順")
    let at = try XCTUnwrap(groups.last?["at"] as? String, "session closed: 群の at")
    let sessions = try XCTUnwrap(groups.last?["sessions"] as? [[String: Any]])
    XCTAssertEqual((sessions.first?["agent"] as? [String: Any])?["sessionId"] as? String, sessionId)

    step(control, ["session", "restore", second], expect: "\(second)\trestored")
    step(control, ["session", "restore", "--at", at], expect: "\(sessionId)\trestored")
    let restoredTabs = try XCTUnwrap(control.orbJSON(["tab", "list"])["tabs"] as? [[String: Any]])
    for id in [sessionId, second] {
      XCTAssertTrue(
        restoredTabs.contains { $0["agentSessionId"] as? String == id },
        "session restore: 休眠チケット \(id) が tab list に agentSessionId 付きで現れる")
    }
    let again = control.orbJSON(["session", "restore", sessionId, second])
    XCTAssertEqual(
      (again["results"] as? [[String: Any]])?.map { $0["status"] as? String },
      ["already-present", "already-present"], "session restore --json: 再実行は already-present")
    XCTAssertTrue(
      try XCTUnwrap(control.orbJSON(["session", "closed"])["groups"] as? [[String: Any]]).isEmpty,
      "session closed: 戻ったものは消える")
    let unknown = control.orb(["session", "restore", "nope-1"])
    XCTAssertEqual(unknown.status, 1, "session restore: 未知 id は exit 1: \(unknown.stderr)")
    XCTAssertTrue(unknown.stdout.contains("nope-1\tunknown"), unknown.stdout)
  }

  /// タブのシェルで bare `orb` が**同梱** CLI へ解決し、走った先がこのインスタンスの自タブになる。
  ///
  /// 2 つを別々に測る。前半は `PATH` 前置そのもの——タブの実 env で `command -v orb` を引き、
  /// 同梱 `bin/orb` に解決することを見る。タブ内の効果だけでは前置は測れない: 開発機の PATH には
  /// 別インスタンスの `orb` が居ることがあり、しかもタブは `ORBE_STATE_DIR` を継承するので、
  /// **どの** `orb` が走ってもこのインスタンスの socket へ届いて後半が通ってしまう。
  ///
  /// 後半は socket 到達——`orb tab new` がこのインスタンスへ届けば、タブが 2 枚になったこと自体が
  /// それを示す。観測をタブ集合の実変化で取るのは、タブのテキストがプロンプトのテーマや rc に依るため。
  func testBareOrbResolvesToBundledCliInsideTab() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(control.target.current.tabs.first, "タブが無い")
    let surface = tab.surface
    XCTAssertEqual(control.target.current.tabs.count, 1, "前提: 1 タブ")

    // PATH 前置の解決先そのもの。`PATH` に種を置くのは、前置が空なら親プロセスの PATH を読むため。
    var env = ["PATH": "/usr/bin:/bin"]
    OrbeRuntimeEnv.inject(into: &env, tabId: tab.id)
    let resolved = ControlProcess.run(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "command -v orb"], env: env)
    let bundled = try XCTUnwrap(BundledResources.root, "同梱物がステージされていない")
      .appendingPathComponent("bin/orb").path
    XCTAssertEqual(
      resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines), bundled,
      "タブの PATH 先頭が同梱 orb へ解決しない（前置が外れると別インスタンスの orb に落ちる）")

    // シェルが rc を読み終える前に送ると tty の type-ahead に賭けることになり、失われた入力は
    // `controlSendText` の無言 no-op として誰も報告しない。プロンプトが描かれてから送る。
    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) {
        !(surface.controlReadText(scrollback: false) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }, "シェルのプロンプトが描かれない（この後の入力は捨てられうる）")

    surface.controlSendText("orb tab new")
    surface.controlSendKey(try XCTUnwrap(ControlKey.parse("enter")))

    XCTAssertTrue(
      waitUntil(ControlProcess.tabSettleTimeout) { control.target.current.tabs.count == 2 },
      "bare `orb` がタブ内で解決していない: \(surface.controlReadText(scrollback: true) ?? "")")
  }
}

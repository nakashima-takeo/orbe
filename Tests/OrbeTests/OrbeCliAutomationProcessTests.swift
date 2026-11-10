import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 実 `orb automation`（`orbe-cli`）を子プロセスで起こし、実 `WindowController` の自動化を set（標準入力の JSON）→ list →
/// pause → run → resume → rm のライフサイクルで動かせること、proposals が自動化の棚の提案を出すことを固定する。ノードは
/// どれもコマンドなので、agent は起きない。
///
/// 壊れると何が起きるか: CLI が組み立てる control メソッド名・params の語（`pause` / `resume` の `paused`、`set` と
/// `proposals` の `automationId`、`set` の `definition`、`run` の `nodeKey`）はここでしか測れない。`resume` が
/// `paused:true` を送ると、exit 0 を返しながら止まったままになる。`--node` が `nodeKey` を落とすと、自動化ごと止まる。`run` が `nodeKey` を落とすと、指したノードの先まで流れる。
/// `runs` が `nodeKey`・`before` を落とすと、AI は別のノードの回や同じページを続きと読む。試走の口は `+Trial` が固定する。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続する（GhosttyKit 必須）。純ロジック検証ではない。
final class OrbeCliAutomationProcessTests: OrbeTestCase {
  /// 回すと取得のノードが項目 a を 1 つ取り、届いたら判定のノード（コマンド）が a を候補に出す。新しい DB で最初に作るノードの ID は
  /// 1 なので、a の下流へ渡す id は `1:a`。
  private let definition = #"""
    {"name": "GitHub: 通知", "nodes": [
      {"key": "fetch", "name": "取る", "trigger": {"kind": "interval", "minutes": 30},
       "coverage": "currentSet", "command":
       "echo '{\"id\":\"a\",\"link\":\"https://x.test/a\",\"body\":\"a\",\"time\":\"2026-01-01T00:00:00Z\"}'"},
      {"key": "judge", "name": "判定", "trigger": {"kind": "arrival"}, "from": ["fetch"],
       "deliver": "taskCandidates",
       "command": "cat >/dev/null; echo '{\"propose\":\"1:a\",\"title\":\"a を見る\"}'"}]}
    """#

  /// `allowFailure` なら終わり方を問わず、標準出力と標準エラーを返す。
  func run(
    _ control: ControlProcess, _ args: [String], stdin: String? = nil, allowFailure: Bool = false,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let outcome = control.orb(["automation"] + args, stdin: stdin, file: file, line: line)
    if allowFailure { return outcome.stdout + outcome.stderr }
    XCTAssertEqual(
      outcome.status, 0,
      "orb automation \(args.joined(separator: " ")) が exit 0 でない: \(outcome.stderr)", file: file,
      line: line)
    return outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `automation list` の人向けの 1 行目（タブ区切りの列）。
  private func row(_ control: ControlProcess) -> [String] {
    run(control, ["list"]).split(separator: "\n").first.map {
      $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    } ?? []
  }

  func testAutomationSubcommandsDriveOneLifecycle() throws {
    let control = try startControlProcess()

    let id = run(control, ["set"], stdin: definition)
    XCTAssertNotNil(Int(id), "automation set: 新しい自動化の ID を出す: \(id)")
    XCTAssertEqual(Array(row(control).prefix(4)), [id, "active", "GitHub: 通知", "every 30m"])
    XCTAssertNotEqual(row(control)[4], "-", "動いている自動化は次の時刻を持つ")

    XCTAssertEqual(run(control, ["pause", id]), "paused automation \(id)")
    XCTAssertEqual(Array(row(control).prefix(2)), [id, "paused"])
    XCTAssertEqual(row(control)[4], "-", "止めた自動化は次の時刻を持たない")

    XCTAssertEqual(run(control, ["run", id]), "started automation \(id)", "止めた自動化も今すぐは受ける")
    XCTAssertTrue(
      waitUntil(10) {
        control.target.automationStore.automation(Int(id)!)?.state(key: "judge").runs.isEmpty
          == false
      }, "今すぐの回の後に、届いたら判定の回が記録に残らない")
    XCTAssertTrue(row(control)[5].hasSuffix(" judge: 1 proposed"), row(control)[5])

    XCTAssertEqual(run(control, ["resume", id]), "resumed automation \(id)")
    XCTAssertEqual(row(control)[1], "active")

    let automation = { control.target.automationStore.automation(Int(id)!) }
    XCTAssertEqual(
      run(control, ["pause", id, "--node", "judge"]), "paused node judge of automation \(id)")
    XCTAssertEqual(automation()?.state(key: "judge").paused, true)
    XCTAssertEqual(row(control)[1], "active", "ノードを止めても自動化は止めない")
    XCTAssertEqual(
      run(control, ["resume", id, "--node", "judge"]), "resumed node judge of automation \(id)")
    XCTAssertEqual(automation()?.state(key: "judge").paused, false)

    var listed = try XCTUnwrap(control.target.automationStore.automation(Int(id)!)?.definition)
    listed.name = "GitHub: 自分宛の通知"
    let renamedText = try XCTUnwrap(
      String(bytes: AutomationWire.encoder().encode(listed), encoding: .utf8))
    XCTAssertTrue(
      run(control, ["set", id], stdin: renamedText, allowFailure: true).contains("--version"),
      "書き換えは版を添える")
    XCTAssertEqual(
      run(control, ["set", id, "--version", "1"], stdin: renamedText), "updated automation \(id)")
    XCTAssertEqual(row(control)[2], "GitHub: 自分宛の通知")
    XCTAssertTrue(
      run(control, ["set", id, "--version", "1"], stdin: renamedText, allowFailure: true)
        .contains("version mismatch: sent 1, current 2"),
      "古い版の書き換えは断る")

    XCTAssertEqual(run(control, ["rm", id]), "removed automation \(id)")
    XCTAssertEqual(run(control, ["list"]), "")
  }

  /// `run --node <鍵>` はそのノードまで流す（下流の手動のノードは走らない）。
  func testRunFlowsToTheGivenNode() throws {
    let control = try startControlProcess()
    let manual = definition.replacingOccurrences(
      of: #"{"kind": "arrival"}"#, with: #"{"kind": "manual"}"#)
    let id = run(control, ["set"], stdin: manual)
    let automation = { control.target.automationStore.automation(Int(id)!) }

    XCTAssertEqual(run(control, ["run", id, "--node", "fetch"]), "started automation \(id)")
    XCTAssertTrue(waitUntil(10) { automation()?.state(key: "fetch").runs.isEmpty == false })
    XCTAssertEqual(automation()?.state(key: "judge").pending.count, 1, "前提: 判定が読めば取る行がある")
    // 鍵が届かず終わりのノードまで流れると、判定は取得の終わりと同じ知らせの中で起こされる（走っているか、もう記録がある）。
    XCTAssertFalse(control.target.automationRunner.isRunning(Int(id)!, "judge"))
    XCTAssertEqual(automation()?.state(key: "judge").runs, [], "道の外の手動のノードは走らない")
  }

  /// 入力の無い副作用のコマンドの前回は、回の記録だけから「コマンドの終わり方」で出る（取得の数を出さない）。
  func testListShowsTheEndingOfASideEffectCommand() throws {
    let control = try startControlProcess()
    let id = run(
      control, ["set"],
      stdin: #"{"name": "日報", "nodes": [{"key": "note", "name": "日報", "#
        + #""trigger": {"kind": "cron", "expression": "0 23 * * *"}, "#
        + #""command": "cat >/dev/null", "deliver": "none"}]}"#)
    XCTAssertEqual(row(control)[3], "cron 0 23 * * *", "cron の予定は式のまま出る")

    XCTAssertEqual(run(control, ["run", id]), "started automation \(id)")
    XCTAssertTrue(
      waitUntil(10) { control.target.automationStore.automation(Int(id)!)?.runs.isEmpty == false },
      "今すぐの回が記録に残らない")
    let last = row(control)[5]
    XCTAssertTrue(last.hasSuffix(" note: command exited 0"), last)
    XCTAssertFalse(last.contains("fetched"), last)
  }

  /// 仕事のノードの前回は「agent の終わり方」で出る。agent は起こさず、回の記録を直に積む。
  func testListShowsTheEndingOfAWorkNode() throws {
    let control = try startControlProcess()
    let id = try XCTUnwrap(
      Int(
        run(
          control, ["set"],
          stdin: #"{"name": "PR を Slack へ", "nodes": [{"key": "post", "name": "投稿", "#
            + #""trigger": {"kind": "cron", "expression": "0 9 * * 1-5"}, "#
            + #""model": "sonnet", "tools": ["Bash(gh search prs:*)"], "instruction": "投稿して", "#
            + #""deliver": "report"}]}"#
        )))
    try control.target.automationStore.record(
      id, nodeKey: "post", at: Date(),
      outcome: .succeeded(
        .work(.done("投稿した")),
        AutomationNodePass.Execution(commandLine: "claude -p", ending: .exited(0), count: 1),
        breach: nil))
    let last = row(control)[5]
    XCTAssertTrue(last.hasSuffix(" post: agent exited 0"), last)
  }

  /// `proposals <id>` はその自動化が出した提案だけを、`proposals` は全部を 1 行 1 提案で出す。
  func testProposalsListsTheShelfOfTheGivenAutomation() throws {
    let control = try startControlProcess()
    let store = control.target.automationStore
    let first = try XCTUnwrap(Int(run(control, ["set"], stdin: definition)))
    let second = try XCTUnwrap(Int(run(control, ["set"], stdin: definition)))
    for (id, item) in [
      (first, WindowControllerAutomationControlTests.item("a")),
      (second, WindowControllerAutomationControlTests.item("b")),
    ] {
      try WindowControllerAutomationControlTests.round(
        store, id, fetched: [item], proposing: [item])
    }
    let b = try XCTUnwrap(store.proposals.first { $0.link == "https://example.com/b" })

    XCTAssertEqual(
      run(control, ["proposals", String(second)]),
      ["\(b.id)", "open", "\(second)", "-", "対応: b", b.link].joined(separator: "\t"))
    XCTAssertEqual(run(control, ["proposals"]).split(separator: "\n").count, 2)
  }

  /// `runs <id>` は回の記録を新しい順に 1 行 1 回（記録の ID と回の要約）で出し、続きがあれば最後に `next <記録の ID>` を出す。
  /// `--node` はそのノードだけ、`--limit` は 1 ページの件数、`--before` は前のページの `next` からの続き。
  func testRunsPagesThePastRunsNewestFirst() throws {
    let control = try startControlProcess()
    let id = try XCTUnwrap(
      Int(
        run(
          control, ["set"],
          stdin: #"{"name": "取得と記録", "nodes": ["#
            + #"{"key": "fetch", "name": "取る", "trigger": {"kind": "interval", "minutes": 30}, "#
            + #""coverage": "currentSet", "command": "true"}, "#
            + #"{"key": "note", "name": "記録", "trigger": {"kind": "manual"}, "from": ["fetch"], "#
            + #""command": "true", "deliver": "none"}]}"#)))
    let store = control.target.automationStore
    let start = Date()
    for (offset, key) in [(0, "fetch"), (60, "note"), (120, "fetch"), (180, "fetch")] {
      try store.record(
        id, nodeKey: key, at: start.addingTimeInterval(TimeInterval(offset)),
        outcome: key == "fetch"
          ? DesignSceneFixtures.fetched([WindowControllerAutomationControlTests.item("a")])
          : DesignSceneFixtures.sideEffected(0))
    }
    let fetches = try XCTUnwrap(store.automation(id)?.state(key: "fetch").runs.map(\.id))
    func lines(_ args: [String]) -> [[String]] {
      run(control, ["runs", String(id)] + args).split(separator: "\n").map {
        $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      }
    }

    let first = lines(["--node", "fetch", "--limit", "2"])
    XCTAssertEqual(first.map(\.[0]), ["\(fetches[0])", "\(fetches[1])", "next"])
    XCTAssertTrue(first[0][1].hasSuffix(" fetch: 1 fetched, 0 new"), first[0][1])
    XCTAssertEqual(first[2][1], "\(fetches[1])")
    XCTAssertEqual(
      lines(["--node", "fetch", "--before", first[2][1]]).map(\.[0]), ["\(fetches[2])"])
    XCTAssertEqual(lines([]).count, 4, "ノードを指さなければ全ノードの回")
  }

  /// 定義の検証は control が持つ。標準入力が JSON オブジェクトでないのは usage エラー（2）、形の欠けは RPC エラー（1）。
  func testSetRejectsBrokenInput() throws {
    let control = try startControlProcess()

    let notJSON = control.orb(["automation", "set"], stdin: "name=x")
    XCTAssertEqual(notJSON.status, 2)
    XCTAssertTrue(notJSON.stderr.contains("stdin is not a JSON object"), notJSON.stderr)

    let missing = control.orb(["automation", "set"], stdin: #"{"name": "x"}"#)
    XCTAssertEqual(missing.status, 1)
    XCTAssertTrue(missing.stderr.contains("error -32602: missing nodes"), missing.stderr)
    XCTAssertTrue(control.target.automationStore.automations.isEmpty)
  }

  /// 数のオプションは、標準入力を読む前・socket に触れる前に usage エラー（2）で確かめる。`set` の `--version` は `<id>` と
  /// 組みでだけ、`try` の `--version` は `<id>` と `--definition` の組みでだけ受け、`<id>` を直す `--definition` には `--version` が要る。
  ///
  /// 壊れると何が起きるか: `orb automation set 3 --version x` が端末で標準入力の終わりを待って止まる。`--version 0` が版の
  /// 食い違いとして返り、誤りの場所が伝わらない。`<id>` の無い `--version` が黙って捨てられ、書き換えのつもりで新しい自動化を
  /// 作る。
  func testNumericOptionsAreCheckedBeforeAnythingElse() {
    for (args, message) in [
      (["set", "1", "--version", "x"], "--version requires a positive <n>"),
      (["set", "1", "--version", "0"], "--version requires a positive <n>"),
      (["set", "--version", "1"], "--version requires the <id>"),
      (["try", "1", "--definition"], "requires --version"),
      (["try", "--version", "1", "--definition"], "--version requires <id> and --definition"),
      (["try", "1", "--version", "1"], "--version requires <id> and --definition"),
      (["try"], "requires <id> or --definition"),
      (["trial", "x"], "invalid trial id: x"),
      (["runs", "1", "--before", "x"], "--before requires a positive <recordId>"),
      (["runs", "1", "--limit", "0"], "--limit requires a positive <n>"),
    ] {
      let outcome = ControlProcess.orbWithoutServer(["automation"] + args)
      let label = "orb automation \(args.joined(separator: " "))"
      XCTAssertEqual(outcome.status, 2, "\(label): \(outcome.stderr)")
      XCTAssertTrue(outcome.stderr.contains(message), "\(label): \(outcome.stderr)")
    }
  }

  /// 各サブコマンドは受ける数より多い位置引数を、socket に触れる前に usage エラー（2）で断る。
  ///
  /// 壊れると何が起きるか: `orb automation rm 3 4` が 3 だけを消して exit 0 を返し、4 も消したつもりの AI が食い違う。
  /// `orb automation list 3` が絞り込みのつもりの 3 を黙って捨てて全件を返す。
  func testSubcommandsRejectExtraPositionals() {
    for args in [
      ["list", "1"], ["proposals", "1", "2"], ["set", "1", "2"], ["run", "1", "2"],
      ["pause", "1", "2"], ["resume", "1", "2"], ["rm", "1", "2"], ["try", "1", "2"],
      ["trial", "1", "2"], ["runs", "1", "2"],
    ] {
      let outcome = ControlProcess.orbWithoutServer(["automation"] + args)
      let label = "orb automation \(args.joined(separator: " "))"
      XCTAssertEqual(outcome.status, 2, "\(label): \(outcome.stderr)")
      XCTAssertTrue(
        outcome.stderr.contains("unexpected argument: \(args.last!)"), "\(label): \(outcome.stderr)"
      )
    }
  }
}

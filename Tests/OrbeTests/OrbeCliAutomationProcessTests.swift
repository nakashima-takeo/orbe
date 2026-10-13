import Foundation
import XCTest

@testable import Orbe

/// 実 `orb automation`（`orbe-cli`）を子プロセスで起こし、実 `WindowController` の自動化を set（標準入力の JSON）→ list →
/// pause → run → resume → rm のライフサイクルで動かせること、proposals が自動化の棚の提案を出すことを固定する。取得元も
/// 段もコマンドなので、agent は起きない。
///
/// 壊れると何が起きるか: CLI が組み立てる control メソッド名・params の語（`pause` / `resume` の `paused`、`set` と
/// `proposals` の `automationId`、`set` の `definition`）はここでしか測れない。`resume` が `paused:true` を送ると、exit 0 を返しながら止まったままになる。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続する（GhosttyKit 必須）。純ロジック検証ではない。
final class OrbeCliAutomationProcessTests: OrbeTestCase {
  /// 回すと項目 a を 1 つ取り、最後の段（コマンド）が a を候補に出す。
  private let definition = #"""
    {"name": "GitHub: 通知", "trigger": {"everyMinutes": 30},
     "source": {"coverage": "currentSet", "command":
       "echo '{\"id\":\"a\",\"link\":\"https://x.test/a\",\"body\":\"a\",\"time\":\"2026-01-01T00:00:00Z\"}'"},
     "steps": [{"name": "判定", "command": "cat >/dev/null; echo '{\"propose\":\"a\",\"title\":\"a を見る\"}'"}],
     "sink": {"kind": "taskCandidates"}}
    """#

  private func run(
    _ control: ControlProcess, _ args: [String], stdin: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let outcome = control.orb(["automation"] + args, stdin: stdin, file: file, line: line)
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
      waitUntil(10) { control.target.automationStore.automation(Int(id)!)?.runs.isEmpty == false },
      "今すぐの回が記録に残らない")
    XCTAssertTrue(row(control)[5].hasSuffix("1 fetched, 1 new, 1 proposed"), row(control)[5])

    XCTAssertEqual(run(control, ["resume", id]), "resumed automation \(id)")
    XCTAssertEqual(row(control)[1], "active")

    let renamedText = definition.replacingOccurrences(of: "GitHub: 通知", with: "GitHub: 自分宛の通知")
    XCTAssertEqual(run(control, ["set", id], stdin: renamedText), "updated automation \(id)")
    XCTAssertEqual(row(control)[2], "GitHub: 自分宛の通知")

    XCTAssertEqual(run(control, ["rm", id]), "removed automation \(id)")
    XCTAssertEqual(run(control, ["list"]), "")
  }

  /// 取得元の無いコマンドの自動化の前回は、回の記録だけから「コマンドの終わり方」で出る（取得の数を出さない）。
  func testListShowsTheEndingOfACommandSink() throws {
    let control = try startControlProcess()
    let id = run(
      control, ["set"],
      stdin: #"{"name": "日報", "trigger": {"dailyAt": ["23:00"]}, "steps": [], "#
        + #""sink": {"kind": "command", "command": "cat >/dev/null"}}"#)

    XCTAssertEqual(run(control, ["run", id]), "started automation \(id)")
    XCTAssertTrue(
      waitUntil(10) { control.target.automationStore.automation(Int(id)!)?.runs.isEmpty == false },
      "今すぐの回が記録に残らない")
    let last = row(control)[5]
    XCTAssertTrue(last.hasSuffix(" command exited 0"), last)
    XCTAssertFalse(last.contains("fetched"), last)
  }

  /// `proposals <id>` はその自動化の棚の提案だけを、`proposals` は全部を 1 行 1 提案で出す。
  func testProposalsListsTheShelfOfTheGivenAutomation() throws {
    let control = try startControlProcess()
    let store = control.target.automationStore
    let first = try XCTUnwrap(Int(run(control, ["set"], stdin: definition)))
    let second = try XCTUnwrap(Int(run(control, ["set"], stdin: definition)))
    for (id, item) in [
      (first, AutomationStoreTests.item("a")), (second, AutomationStoreTests.item("b")),
    ] {
      AutomationStoreTests.commit(
        store, id, AutomationStoreTests.run(at: Date()), fetched: [item],
        decisions: [.propose(itemId: item.id, title: "対応: \(item.id)", due: nil)])
    }
    let b = try XCTUnwrap(store.proposals.first { $0.item.id == "b" })

    XCTAssertEqual(
      run(control, ["proposals", String(second)]),
      ["\(b.id)", "open", "\(second)", "-", "対応: b", b.item.link].joined(separator: "\t"))
    XCTAssertEqual(run(control, ["proposals"]).split(separator: "\n").count, 2)
  }

  /// 定義の検証は control が持つ。標準入力が JSON オブジェクトでないのは usage エラー（2）、形の欠けは RPC エラー（1）。
  func testSetRejectsBrokenInput() throws {
    let control = try startControlProcess()

    let notJSON = control.orb(["automation", "set"], stdin: "name=x")
    XCTAssertEqual(notJSON.status, 2)
    XCTAssertTrue(notJSON.stderr.contains("stdin is not a JSON object"), notJSON.stderr)

    let missing = control.orb(["automation", "set"], stdin: #"{"name": "x"}"#)
    XCTAssertEqual(missing.status, 1)
    XCTAssertTrue(missing.stderr.contains("error -32602: missing trigger"), missing.stderr)
    XCTAssertTrue(control.target.automationStore.automations.isEmpty)
  }

  /// 各サブコマンドは受ける数より多い位置引数を、socket に触れる前に usage エラー（2）で断る。
  ///
  /// 壊れると何が起きるか: `orb automation rm 3 4` が 3 だけを消して exit 0 を返し、4 も消したつもりの AI が食い違う。
  /// `orb automation list 3` が絞り込みのつもりの 3 を黙って捨てて全件を返す。
  func testSubcommandsRejectExtraPositionals() {
    for args in [
      ["list", "1"], ["proposals", "1", "2"], ["set", "1", "2"], ["run", "1", "2"],
      ["pause", "1", "2"], ["resume", "1", "2"], ["rm", "1", "2"],
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

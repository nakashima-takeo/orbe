import Foundation
import XCTest

@testable import Orbe

/// 実 `orb task`（`orbe-cli`）を子プロセスで起こし、実 `WindowController` の一覧を list → add → set →
/// move → rm のライフサイクルで動かせること、タブの中から打った `add` がそのタブの workspace に付くことを固定する。
///
/// 1 本に束ねているのは、後段が前段で足したタスクを前提にする連鎖だから（`OrbeCliProcessTests` と同じ理由）。
///
/// 壊れると何が起きるか: CLI が組み立てる control メソッド名・params の語（`--no-due` を null で送る等）は
/// ここでしか測れない。`--no-due` が「キー無し」で送られると、exit 0 を返しながら期限が残る。`ORBE_TAB` を
/// 添え損ねると、タブ内の agent が足したタスクがどの workspace にも付かない。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続する（GhosttyKit 必須）。純ロジック検証ではない。
final class OrbeCliTaskProcessTests: OrbeTestCase {
  private func run(
    _ control: ControlProcess, _ args: [String], env: [String: String] = [:],
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let outcome = control.orb(["task"] + args, env: env, file: file, line: line)
    XCTAssertEqual(
      outcome.status, 0, "orb task \(args.joined(separator: " ")) が exit 0 でない: \(outcome.stderr)",
      file: file, line: line)
    return outcome.stdout
  }

  /// `task list` の人向けの行（タブ区切りの列）。
  private func rows(_ control: ControlProcess) -> [[String]] {
    run(control, ["list"]).split(separator: "\n").map {
      $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }
  }

  private func tasks(_ control: ControlProcess, env: [String: String] = [:]) throws -> [[String:
    Any]]
  {
    try XCTUnwrap(control.orbJSON(["task", "list"], env: env)["tasks"] as? [[String: Any]])
  }

  private func workspaceId(_ control: ControlProcess, _ name: String) throws -> Int {
    try XCTUnwrap(
      control.target.controlListWorkspaces().first { $0["name"] as? String == name }?["id"] as? Int)
  }

  func testTaskSubcommandsDriveOneLifecycle() throws {
    let control = try startControlProcess()
    let background = try workspaceId(control, "background")

    let first = run(control, ["add", "経費精算を出す", "--due", "2026-10-06", "--priority", "high"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let second = run(control, ["add", "承認を取る", "--waiting", "部長の返事", "--memo", "メモ"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(first), "task add: 新しいタスクの ID を出す: \(first)")
    XCTAssertEqual(
      rows(control),
      [
        [first, "todo", "high", "2026-10-06", "-", "経費精算を出す", "-", "-"],
        [second, "todo", "medium", "-", "-", "承認を取る", "部長の返事", "-"],
      ], "task list: 1 行 1 タスク（ID・ステータス・優先度・期限・workspace・タイトル・待ち・結び付き）で、追加順に末尾へ並ぶ")
    XCTAssertEqual(try tasks(control)[1]["memo"] as? String, "メモ", "task add --memo")

    run(control, ["set", second, "--status", "done"])
    XCTAssertEqual(rows(control).last?[1], "done", "task set --status")
    XCTAssertEqual(rows(control).last?[6], "-", "task set --status done: 待ちが外れる")

    run(
      control,
      [
        "set", first, "--title", "経費精算", "--priority", "low", "--no-due", "--waiting", "領収書",
        "--workspace", String(background),
      ])
    XCTAssertEqual(
      rows(control).first, [first, "todo", "low", "-", "background", "経費精算", "領収書", "-"],
      "task set: 渡した項目だけ変わり、--no-due で期限が外れる")
    let filtered = try XCTUnwrap(
      control.orbJSON(["task", "list", "--workspace", String(background)])["tasks"]
        as? [[String: Any]])
    XCTAssertEqual(
      filtered.compactMap { $0["taskId"] as? Int }, [Int(first)].compactMap { $0 },
      "task list --workspace: その workspace のタスクだけに絞る")

    run(control, ["set", first, "--no-waiting", "--no-workspace", "--status", "in_progress"])
    run(control, ["set", second, "--no-memo"])
    let afterClear = try tasks(control)
    XCTAssertNil(afterClear[0]["waiting"], "task set --no-waiting")
    XCTAssertNil(afterClear[0]["workspaceId"], "task set --no-workspace")
    XCTAssertEqual(afterClear[0]["status"] as? String, "in_progress")
    XCTAssertEqual(afterClear[1]["memo"] as? String, "", "task set --no-memo")

    run(control, ["move", second, "--before", first])
    XCTAssertEqual(rows(control).map { $0[0] }, [second, first], "task move --before")
    run(control, ["move", second, "--after", first])
    XCTAssertEqual(rows(control).map { $0[0] }, [first, second], "task move --after")

    run(control, ["rm", first])
    XCTAssertEqual(rows(control).map { $0[0] }, [second], "task rm")

    let rejected = control.orb(["task", "set", first, "--title", "x"])
    XCTAssertEqual(rejected.status, 1, "消したタスクの変更は control のエラーで exit 1")
    XCTAssertTrue(rejected.stderr.contains("-32004"), rejected.stderr)
    let unknownStatus = control.orb(["task", "add", "x", "--status", "finished"])
    XCTAssertEqual(unknownStatus.status, 1, "語彙の外のステータスは control が弾く（CLI は素通し）")
    XCTAssertTrue(unknownStatus.stderr.contains("-32602"), unknownStatus.stderr)
    XCTAssertEqual(rows(control).count, 1, "拒否された要求は一覧を変えない")
  }

  /// `--issue` / `--pr` は引数に現れた順のまま結び付き（先頭が主）、`set` は丸ごと置き換え、
  /// `--no-links` で全部外す。`owner/name` の形は control が弾く（CLI は素通し）。
  func testLinksKeepTheArgumentOrderAndSetReplacesOrClearsThem() throws {
    let control = try startControlProcess()

    let id = run(
      control, ["add", "a", "--issue", "o/n#221", "--pr", "O/N#214", "--issue", "x/y.js#5"]
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(
      rows(control).first?[7], "issue:o/n#221,pr:o/n#214,issue:x/y.js#5",
      "task list の 8 列目: 引数の順のまま kind:repo#number")
    XCTAssertEqual(
      (try tasks(control).first?["links"] as? [[String: Any]])?.map {
        NSDictionary(dictionary: $0)
      },
      [
        ["kind": "issue", "repo": "o/n", "number": 221],
        ["kind": "pr", "repo": "o/n", "number": 214],
        ["kind": "issue", "repo": "x/y.js", "number": 5],
      ], "task list --json: links の列")

    run(control, ["set", id, "--pr", "o/n#5"])
    XCTAssertEqual(rows(control).first?[7], "pr:o/n#5", "task set: 結び付きを丸ごと置き換える")
    run(control, ["set", id, "--no-links"])
    XCTAssertEqual(rows(control).first?[7], "-", "task set --no-links: 全部外す")

    let unshaped = control.orb(["task", "add", "b", "--issue", "orbe#5"])
    XCTAssertEqual(unshaped.status, 1, "owner/name の形でないリポジトリは control が弾く")
    XCTAssertTrue(unshaped.stderr.contains("-32602"), unshaped.stderr)
    XCTAssertEqual(rows(control).count, 1, "拒否された要求は一覧を変えない")
  }

  /// 人向けの行のセルは、向きを変える制御文字（U+202E など）を空白にし、ZWJ で組む絵文字は残す。
  /// 向きを変える文字が残ると、後続の列（待ちの理由など）が端末上で入れ替わって見える。
  func testListCellsBlankDirectionOverridesButKeepJoinedEmoji() throws {
    let control = try startControlProcess()
    run(control, ["add", "a\u{202E}b\u{2066}c 🧑‍💻", "--waiting", "x\u{202D}y"])

    XCTAssertEqual(rows(control).first?[5], "a b c 🧑‍💻", "タイトルの向き制御は空白、ZWJ は残る")
    XCTAssertEqual(rows(control).first?[6], "x y", "待ちの理由も同じ")
  }

  /// タブ内の agent が workspace を省いて足すと、そのタブの workspace に付き、agent が追加者になる。
  /// `--workspace current` は呼び出し元タブではなく前面の workspace を指す。
  func testAddInsideATabAttachesToThatTabsWorkspace() throws {
    let control = try startControlProcess()
    let tab = try XCTUnwrap(control.target.workspaces.first { $0.name == "background" }?.tabs.first)
    control.target.controlReportAgent(
      tab: tab, report: AgentHookReport(agent: "claude", state: "working", sessionId: "s-1"))
    let inTab = ["ORBE_TAB": String(tab.id)]

    run(control, ["add", "省略"], env: inTab)
    run(control, ["add", "前面", "--workspace", "current"], env: inTab)
    run(control, ["add", "なし", "--no-workspace"], env: inTab)
    run(control, ["add", "タブの外"])

    let listed = try tasks(control)
    XCTAssertEqual(listed.map { $0["workspaceName"] as? String }, ["background", "main", nil, nil])
    XCTAssertEqual(listed.map { $0["createdBy"] as? String }, ["claude", "claude", "claude", nil])
  }

  /// 引数だけで判る誤りは socket に触れる前に exit 2 で弾く。
  func testUsageErrorsAreRejectedBeforeTouchingTheSocket() {
    for (args, message) in [
      (["task", "add"], "task add requires <title>"),
      (["task", "set", "1"], "task set requires at least one field to change"),
      (
        ["task", "set", "1", "--due", "2026-10-06", "--no-due"], "pass only one of --due / --no-due"
      ),
      (["task", "set", "1", "--memo", "m", "--no-memo"], "pass only one of --memo / --no-memo"),
      (
        ["task", "add", "a", "--workspace", "1", "--no-workspace"],
        "pass only one of --workspace / --no-workspace"
      ),
      (["task", "move", "1"], "task move requires exactly one of --before / --after"),
      (
        ["task", "move", "1", "--before", "2", "--after", "3"],
        "task move requires exactly one of --before / --after"
      ),
      (
        ["task", "set", "1", "--issue", "o/n#1", "--no-links"],
        "pass only one of --issue / --pr / --no-links"
      ),
      (["task", "add", "a", "--issue", "o/n"], "--issue requires an <owner/name#N>: o/n"),
      (["task", "add", "a", "--pr", "o/n#0"], "--pr requires an <owner/name#N>: o/n#0"),
      (["task", "add", "a", "--pr", "o/n#x"], "--pr requires an <owner/name#N>: o/n#x"),
      (["task", "rm", "abc"], "invalid task id: abc"),
      (["task", "rm", "0"], "invalid task id: 0"),
    ] {
      let outcome = ControlProcess.orbWithoutServer(args)
      XCTAssertEqual(
        outcome.status, 2, "\(args.joined(separator: " ")) は exit 2: \(outcome.stderr)")
      XCTAssertTrue(
        outcome.stderr.contains(message),
        "\(args.joined(separator: " ")) の stderr に \"\(message)\" が無い: \(outcome.stderr)")
    }
  }

  /// 値の席に置かれた `-h` を help と読まない（`testHelpInAValueSlotIsNotTreatedAsHelp` の task 版）。
  /// メモや待ちの理由は任意の文字列なので、`orb task set 3 --memo "$M"` の `$M` がたまたま `-h` だと、
  /// 何も変えないまま usage を出して exit 0 になる。値の席の `-` 始まりは exit 2 で止まるのが cli.md の規約。
  func testHelpInAValueSlotIsNotTreatedAsHelp() {
    for args in [
      ["task", "set", "3", "--memo", "-h"],
      ["task", "add", "a", "--waiting", "--help"],
    ] {
      let outcome = ControlProcess.orbWithoutServer(args)
      XCTAssertEqual(
        outcome.status, 2, "`\(args.joined(separator: " "))` が help に化けて exit \(outcome.status)")
      XCTAssertFalse(outcome.stdout.contains("orb task — "), "usage を出して成功扱いにしない")
    }
    // `--help` 自体は従来どおり出る（値の席を抜いた後に残っていれば help）。
    let help = ControlProcess.orbWithoutServer(["task", "set", "--help"])
    XCTAssertEqual(help.status, 0, "task set --help は exit 0: \(help.stderr)")
    XCTAssertTrue(help.stdout.contains("orb task — "), "task set --help は usage を出す")
  }
}

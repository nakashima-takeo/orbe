import Foundation
import XCTest

@testable import Orbe

/// 実 `orb intake`（`orbe-cli`）を子プロセスで起こし、実 `WindowController` の受信を set（標準入力の JSON）→ list →
/// pause → run → resume → rm のライフサイクルで動かせることを固定する。取得は何も出さないコマンドなので、判定の agent は
/// 起きない。
///
/// 壊れると何が起きるか: CLI が組み立てる control メソッド名・params の語（`pause` / `resume` の `paused`、`set` の
/// `intakeId`）はここでしか測れない。`resume` が `paused:true` を送ると、exit 0 を返しながら止まったままになる。
///
/// 重要: 実 `NSWindow` に `SurfaceView` を接続する（GhosttyKit 必須）。純ロジック検証ではない。
final class OrbeCliIntakeProcessTests: OrbeTestCase {
  private let definition = """
    {"name": "GitHub: 通知", "fetch": {"command": "true"},
     "judge": {"model": "haiku", "instruction": "自分がやること"}, "when": {"everyMinutes": 30}}
    """

  private func run(
    _ control: ControlProcess, _ args: [String], stdin: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let outcome = control.orb(["intake"] + args, stdin: stdin, file: file, line: line)
    XCTAssertEqual(
      outcome.status, 0,
      "orb intake \(args.joined(separator: " ")) が exit 0 でない: \(outcome.stderr)", file: file,
      line: line)
    return outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `intake list` の人向けの 1 行目（タブ区切りの列）。
  private func row(_ control: ControlProcess) -> [String] {
    run(control, ["list"]).split(separator: "\n").first.map {
      $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    } ?? []
  }

  func testIntakeSubcommandsDriveOneLifecycle() throws {
    let control = try startControlProcess()

    let id = run(control, ["set"], stdin: definition)
    XCTAssertNotNil(Int(id), "intake set: 新しい受信の ID を出す: \(id)")
    XCTAssertEqual(Array(row(control).prefix(4)), [id, "active", "GitHub: 通知", "every 30m"])
    XCTAssertNotEqual(row(control)[4], "-", "動いている受信は次の時刻を持つ")

    XCTAssertEqual(run(control, ["pause", id]), "paused intake \(id)")
    XCTAssertEqual(Array(row(control).prefix(2)), [id, "paused"])
    XCTAssertEqual(row(control)[4], "-", "止めた受信は次の時刻を持たない")

    XCTAssertEqual(run(control, ["run", id]), "started intake \(id)", "止めた受信も今すぐは受ける")
    XCTAssertTrue(
      waitUntil(10) { control.target.intakeStore.intake(Int(id)!)?.runs.isEmpty == false },
      "今すぐの回が記録に残らない")
    XCTAssertTrue(row(control)[5].hasSuffix("0 fetched, 0 new, 0 proposed"), row(control)[5])

    XCTAssertEqual(run(control, ["resume", id]), "resumed intake \(id)")
    XCTAssertEqual(row(control)[1], "active")

    let renamedText = definition.replacingOccurrences(of: "GitHub: 通知", with: "GitHub: 自分宛の通知")
    XCTAssertEqual(run(control, ["set", id], stdin: renamedText), "updated intake \(id)")
    XCTAssertEqual(row(control)[2], "GitHub: 自分宛の通知")

    XCTAssertEqual(run(control, ["rm", id]), "removed intake \(id)")
    XCTAssertEqual(run(control, ["list"]), "")
  }

  /// 定義の検証は control が持つ。標準入力が JSON オブジェクトでないのは usage エラー（2）、形の欠けは RPC エラー（1）。
  func testSetRejectsBrokenInput() throws {
    let control = try startControlProcess()

    let notJSON = control.orb(["intake", "set"], stdin: "name=x")
    XCTAssertEqual(notJSON.status, 2)
    XCTAssertTrue(notJSON.stderr.contains("stdin is not a JSON object"), notJSON.stderr)

    let missing = control.orb(["intake", "set"], stdin: #"{"name": "x"}"#)
    XCTAssertEqual(missing.status, 1)
    XCTAssertTrue(missing.stderr.contains("error -32602: missing fetch"), missing.stderr)
    XCTAssertTrue(control.target.intakeStore.intakes.isEmpty)
  }
}

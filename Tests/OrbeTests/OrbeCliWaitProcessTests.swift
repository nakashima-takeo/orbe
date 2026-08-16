import Foundation
import XCTest

@testable import Orbe

/// `orb wait`（状態変化の長ポーリング）の終了コードと出力先を実バイナリで固定する。
///
/// 壊れると何が起きるか: `orb wait <pane> --kind agent_state && 次の処理` が、待っていたことが
/// **起きていないのに**次へ進む。時間切れを exit 0 で返すのがまさにその形で、終了コードにも
/// stdout にも現れない（非 --json の `timed out` を stdout へ出すと `text=$(orb wait …)` が
/// 偽のイベントを掴む）。未知 kind も同じ穴で、素のフィルタに通すと永久に一致せずただ時間切れになり
/// 「何も起きなかった」と区別できない。
///
/// `--timeout-ms` は必ず `ControlProcess.processTimeout`（20 秒）より十分小さく取る。
final class OrbeCliWaitProcessTests: OrbeTestCase {
  /// 時間切れを測る待機の宛先。**実在しないペイン**を指す——fixture のペインは起きたシェルが
  /// OSC 7 で `pwd` を撃つので、フィルタ無しで待つと本物のイベントで起きてしまい、
  /// 時間切れの経路を測れない（測っているつもりで exit 0 の側を見ることになる）。
  private let silentPane = "999999"

  /// `--json` のタイムアウトは control の result をそのまま stdout へ載せ、exit 124。
  func testTimeoutExits124WithTimedOutPayload() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let outcome = control.orb(["wait", silentPane, "--timeout-ms", "300", "--json"])

    XCTAssertEqual(outcome.status, 124, "時間切れは exit 124（成功していないのに 0 を返さない）")
    let data = try XCTUnwrap(outcome.stdout.data(using: .utf8))
    let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(result["timedOut"] as? Bool, true, "--json は control の result をそのまま出す")
  }

  /// 非 `--json` の時間切れは **stdout を汚さず** stderr へ理由を出す。
  func testTimeoutKeepsStdoutCleanWithoutJson() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let outcome = control.orb(["wait", silentPane, "--timeout-ms", "300"])

    XCTAssertEqual(outcome.status, 124, "非 --json でも時間切れは exit 124")
    XCTAssertTrue(
      outcome.stdout.isEmpty, "時間切れで stdout を汚さない（`$(orb wait …)` が偽の値を掴む）: \(outcome.stdout)")
    XCTAssertTrue(outcome.stderr.contains("timed out"), "理由は stderr へ: \(outcome.stderr)")
  }

  /// イベントで起きたら exit 0 と `event`。`orb` を起こす**前**に発火を予約し、子を待つあいだ回る
  /// runloop でそれを撃つ（`ControlProcess.run` は main を塞がずに待つ）。
  func testEventWakesTheWaitAndExitsZero() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let pane = try XCTUnwrap(
      control.target.current.tabs.first?.controlAllPanes().first, "ペインが無い")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      control.target.controlReportAgent(
        pane: pane, agent: "codex", state: "working", sessionId: nil, message: nil)
    }

    let outcome = control.orb(
      ["wait", "\(pane.id)", "--kind", "agent_state", "--timeout-ms", "8000", "--json"])
    XCTAssertEqual(outcome.status, 0, "イベントで起きたら exit 0: \(outcome.stdout)\(outcome.stderr)")
    let data = try XCTUnwrap(outcome.stdout.data(using: .utf8))
    let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let event = try XCTUnwrap(
      result["event"] as? [String: Any], "起きた側は event を返す: \(outcome.stdout)")
    XCTAssertEqual(event["kind"] as? String, "agent_state")
    XCTAssertEqual(event["paneId"] as? Int, pane.id)
    XCTAssertEqual(event["value"] as? String, "working")
  }

  /// 未知 kind は control が -32602 で弾く（exit 1）。CLI は 4 語を複製しないので、
  /// ここが「黙って時間切れ」に戻っていないことを見る唯一の場所になる。
  func testUnknownKindIsRejectedByControlInsteadOfTimingOut() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let outcome = control.orb(["wait", "--kind", "nosuch", "--timeout-ms", "300"])

    XCTAssertEqual(outcome.status, 1, "未知 kind は RPC エラー（時間切れの 124 でも成功の 0 でもない）")
    XCTAssertTrue(
      outcome.stderr.contains("-32602") && outcome.stderr.contains("unknown kind"),
      "未知 kind の理由が残る: \(outcome.stderr)")
  }

  /// `--timeout-ms` の値の席は CLI が握る（socket へ行く前に exit 2）。
  func testInvalidTimeoutIsAUsageError() {
    for args in [
      ["wait", "--timeout-ms", "0"], ["wait", "--timeout-ms", "abc"], ["wait", "--timeout-ms"],
    ] {
      let outcome = ControlProcess.orbWithoutServer(args, env: ["ORBE_PANE": "1"])
      XCTAssertEqual(
        outcome.status, 2, "`\(args.joined(separator: " "))` は usage エラー: \(outcome.stderr)")
      XCTAssertTrue(
        outcome.stderr.contains("--timeout-ms requires a positive <milliseconds>"),
        "期待する値の形を言う: \(outcome.stderr)")
    }
  }

  /// `orb wait --help` の `KINDS:` は control の `ControlEvent.kinds` と同じ集合。
  ///
  /// CLI は kind の語彙を持たない（弾くのは control）が、help だけは socket 不達でも出す必要が
  /// あるため 4 語を写している。その写しのドリフトは、`config --help` の `KEYS:` と同じ手で落とす。
  func testWaitHelpListsEveryEventKind() throws {
    let outcome = ControlProcess.orbWithoutServer(["wait", "--help"])
    XCTAssertEqual(outcome.status, 0, "wait --help は socket 不達でも exit 0: \(outcome.stderr)")
    let line = try XCTUnwrap(
      outcome.stdout.split(separator: "\n").first { $0.hasPrefix("KINDS: ") },
      "wait --help に KINDS: 行が無い: \(outcome.stdout)")
    let listed = line.dropFirst("KINDS: ".count).split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    XCTAssertEqual(
      Set(listed), ControlEvent.kinds, "wait --help の KINDS が ControlEvent.kinds と食い違っている")
  }
}

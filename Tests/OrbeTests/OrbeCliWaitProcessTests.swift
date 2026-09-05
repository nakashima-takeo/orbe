import Foundation
import XCTest

@testable import Orbe

/// `orb wait`（状態変化の長ポーリング）の終了コードと出力先を実バイナリで固定する。
///
/// 壊れると何が起きるか: `orb wait <tab> --kind agent_state && 次の処理` が、待っていたことが
/// **起きていないのに**次へ進む。時間切れを exit 0 で返すのがまさにその形で、終了コードにも
/// stdout にも現れない（非 --json の `timed out` を stdout へ出すと `text=$(orb wait …)` が
/// 偽のイベントを掴む）。未知 kind も同じ穴で、素のフィルタに通すと永久に一致せずただ時間切れになり
/// 「何も起きなかった」と区別できない。
///
/// `--timeout-ms` は必ず `ControlProcess.processTimeout`（20 秒）より十分小さく取る。
final class OrbeCliWaitProcessTests: OrbeTestCase {
  /// 時間切れを測る待機の宛先。**実在しないタブ**を指す——fixture のタブは起きたシェルが
  /// OSC 7 で `pwd` を撃つので、フィルタ無しで待つと本物のイベントで起きてしまい、
  /// 時間切れの経路を測れない（測っているつもりで exit 0 の側を見ることになる）。
  private let silentTab = "999999"

  /// `--json` のタイムアウトは control の result をそのまま stdout へ載せ、exit 124。
  func testTimeoutExits124WithTimedOutPayload() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let outcome = control.orb(["wait", silentTab, "--timeout-ms", "300", "--json"])

    XCTAssertEqual(outcome.status, 124, "時間切れは exit 124（成功していないのに 0 を返さない）")
    let data = try XCTUnwrap(outcome.stdout.data(using: .utf8))
    let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(result["timedOut"] as? Bool, true, "--json は control の result をそのまま出す")
  }

  /// 非 `--json` の時間切れは **stdout を汚さず** stderr へ理由を出す。
  func testTimeoutKeepsStdoutCleanWithoutJson() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let outcome = control.orb(["wait", silentTab, "--timeout-ms", "300"])

    XCTAssertEqual(outcome.status, 124, "非 --json でも時間切れは exit 124")
    XCTAssertTrue(
      outcome.stdout.isEmpty, "時間切れで stdout を汚さない（`$(orb wait …)` が偽の値を掴む）: \(outcome.stdout)")
    XCTAssertTrue(outcome.stderr.contains("timed out"), "理由は stderr へ: \(outcome.stderr)")
  }

  /// 子が待機を登録し終えるまで `agent_state` を撃ち続けるタイマーを張る。
  ///
  /// 単発の予約（`asyncAfter`）だと「子の起動が予約時刻に間に合う」に賭けることになり、リンク直後の
  /// cold バイナリでは実際に間に合わず、退行が無いのに 124 で赤くなる。イベントはバッファされない
  /// （待機者ゼロなら捨てられる）ので、繰り返し撃てば実時間への依存が構造的に消える。
  ///
  /// 毎回 idle→working と振るのは、`agentState` の didSet が**値が変わったときだけ** emit するから
  /// ——同じ状態を撃ち続けても 2 回目以降は何も出ない。よって掴む値は idle と working のどちらもある。
  private func pumpAgentState(_ control: ControlProcess, tab: TerminalTab) -> DispatchSourceTimer {
    let ticker = DispatchSource.makeTimerSource(queue: .main)
    ticker.schedule(deadline: .now(), repeating: .milliseconds(100))
    ticker.setEventHandler {
      control.target.controlReportAgent(
        tab: tab, agent: "codex", state: "idle", sessionId: nil, message: nil)
      control.target.controlReportAgent(
        tab: tab, agent: "codex", state: "working", sessionId: nil, message: nil)
    }
    ticker.resume()
    return ticker
  }

  /// イベントで起きたら exit 0 と `event`。
  func testEventWakesTheWaitAndExitsZero() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(
      control.target.current.tabs.first, "タブが無い")

    let ticker = pumpAgentState(control, tab: tab)
    defer { ticker.cancel() }

    // `--kind` は反復できる（`takeOptions`）。2 個目を素の `takeOption` で書き戻すと残余に落ちて
    // `unknown option: --kind` になるので、ここで 2 語渡して拾えていることまで見る。
    let outcome = control.orb(
      [
        "wait", "\(tab.id)", "--kind", "agent_state", "--kind", "tab_closed",
        "--timeout-ms", "8000", "--json",
      ])
    XCTAssertEqual(outcome.status, 0, "イベントで起きたら exit 0: \(outcome.stdout)\(outcome.stderr)")
    let data = try XCTUnwrap(outcome.stdout.data(using: .utf8))
    let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let event = try XCTUnwrap(
      result["event"] as? [String: Any], "起きた側は event を返す: \(outcome.stdout)")
    XCTAssertEqual(event["kind"] as? String, "agent_state", "指定した kind のイベントで起きる")
    XCTAssertEqual(event["tabId"] as? Int, tab.id)
    XCTAssertTrue(
      ["idle", "working"].contains(event["value"] as? String ?? ""),
      "撃った状態語のどちらかを載せる: \(outcome.stdout)")
  }

  /// `<tab>` 省略は **ORBE_TAB を継がず**全タブを見る。tab 系（`resolveTabArg`）と揃えると、
  /// タブ内で走らせたスクリプトの `orb wait` が黙って自タブだけに絞られ、他タブを待っていた
  /// 側は 124 で「何も起きなかった」と読む——同じコマンドが環境によって違う意味になる。
  func testWaitDoesNotFallBackToOrbeTab() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(
      control.target.current.tabs.first, "タブが無い")

    let ticker = pumpAgentState(control, tab: tab)
    defer { ticker.cancel() }

    // ORBE_TAB は実在しないタブを指す。継いでいればそこに絞られて 124 になる。
    let outcome = control.orb(
      ["wait", "--kind", "agent_state", "--timeout-ms", "8000", "--json"],
      env: ["ORBE_TAB": silentTab])
    XCTAssertEqual(
      outcome.status, 0,
      "<tab> 省略が ORBE_TAB に絞られている（全タブを見るのが契約）: \(outcome.stdout)\(outcome.stderr)")
    let data = try XCTUnwrap(outcome.stdout.data(using: .utf8))
    let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let event = try XCTUnwrap(result["event"] as? [String: Any], "起きた側は event を返す")
    XCTAssertEqual(event["tabId"] as? Int, tab.id, "ORBE_TAB ではなく実際に鳴ったタブを返す")
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

  /// `--after <seq>` は、その seq より後に**既に起きた**一致イベントも返す。seq の出所は他の `--json`
  /// 応答（ここでは `tab list`）で、待機を張る前に済んだ遷移——`orb tab send` → `orb wait` の隙間
  /// ——を取りこぼさない。`--value` は状態語の一致で絞る（idle も撃っているので、value が効かなければ
  /// idle の方が先に返る）。
  func testAfterReplaysAnEventThatHappenedBeforeTheWait() throws {
    let control = try startControlProcess(workspaces: ["main"])
    let tab = try XCTUnwrap(
      control.target.current.tabs.first, "タブが無い")
    let before = try XCTUnwrap(control.orbJSON(["tab", "list"])["seq"] as? Int, "seq の出所")

    control.target.controlReportAgent(
      tab: tab, agent: "codex", state: "idle", sessionId: nil, message: nil)
    control.target.controlReportAgent(
      tab: tab, agent: "codex", state: "working", sessionId: nil, message: nil)

    let outcome = control.orb(
      [
        "wait", "\(tab.id)", "--kind", "agent_state", "--value", "working",
        "--after", "\(before)", "--timeout-ms", "3000", "--json",
      ])
    XCTAssertEqual(outcome.status, 0, "既に起きた遷移で即返る: \(outcome.stdout)\(outcome.stderr)")
    let data = try XCTUnwrap(outcome.stdout.data(using: .utf8))
    let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let event = try XCTUnwrap(result["event"] as? [String: Any], "起きた側は event を返す")
    XCTAssertEqual(event["value"] as? String, "working", "--value で絞った状態語のイベント")
    let seq = try XCTUnwrap(event["seq"] as? Int, "event は seq を持つ")
    XCTAssertGreaterThan(seq, before, "返るのは --after より後のイベント")
    XCTAssertEqual(result["seq"] as? Int, seq, "応答の seq はそのイベントの seq")
  }

  /// `--after` は 0 を通し、負・非数値は socket に触れる前の usage エラー。
  func testAfterAcceptsZeroAndRejectsNegativeOrNonNumeric() {
    for value in ["-1", "abc"] {
      let outcome = ControlProcess.orbWithoutServer(["wait", "--after", value])
      XCTAssertEqual(outcome.status, 2, "`--after \(value)` は usage エラー: \(outcome.stderr)")
      XCTAssertTrue(
        outcome.stderr.contains("--after requires a non-negative <seq>"),
        "期待する値の形を言う: \(outcome.stderr)")
    }
    let zero = ControlProcess.orbWithoutServer(["wait", "--after", "0"])
    XCTAssertEqual(zero.status, 1, "--after 0 は usage を通り、socket 不達（exit 1）まで進む: \(zero.stderr)")
  }

  /// `--timeout-ms` の値の席は CLI が握る（socket へ行く前に exit 2）。
  func testInvalidTimeoutIsAUsageError() {
    for args in [
      ["wait", "--timeout-ms", "0"], ["wait", "--timeout-ms", "abc"], ["wait", "--timeout-ms"],
    ] {
      let outcome = ControlProcess.orbWithoutServer(args, env: ["ORBE_TAB": "1"])
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

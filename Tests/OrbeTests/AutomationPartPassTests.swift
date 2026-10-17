import OrbeSessionLog
import XCTest

@testable import Orbe

/// 部品の 1 回——役割どおりに手段を起こし（上限・目印・標準入力・回の ID・ツール）、役割ごとに出力を読む（取得の差分と接頭と
/// 出どころ、処理の出どころの照らしと `id` の無い行、判定の候補の出どころ、仕事と副作用の失敗）。止めた回は何も返さない。
///
/// 壊れると何が起きるか: 長く黙って考える agent が途中で切られる。今の集合の取得が前回以降の分だけを取り、候補が一斉に下がる。
/// 副作用のやり直しに回の ID が渡らず二重に起きる。仕事の agent がツール無しで起き、何もせずに成功する。前回取れた項目が
/// 毎回流れ直す、または出どころの id が接頭付きになり前回の出力と照らせない。`id` を落とした処理の行が黙って消える。候補に
/// 別の項目のリンクが付く。失敗した取得・仕事・副作用が成功として確定する。止めた回の結果が書き換えた後の定義で確定する。
final class AutomationPartPassTests: OrbeTestCase {
  private static let tool = AutomationGraphTests.tool
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private var jobs: FakeJobs!
  private var pass: AutomationPartPass!
  private var outcomes: [AutomationPartPass.Outcome] = []

  override func setUp() {
    jobs = FakeJobs()
    pass = AutomationPartPass(
      run: jobs.run, now: { [unowned self] in now },
      calendar: { Calendar(identifier: .gregorian) })
  }

  @discardableResult
  private func start(
    _ part: AutomationPart, _ role: AutomationPartRole, _ input: AutomationPartPass.Input
  ) -> BackgroundRunHandle {
    pass.start(AutomationGraph.Node(part: part, role: role), input) { [unowned self] in
      outcomes.append($0)
    }
  }

  private func item(_ id: String) -> AutomationItem {
    AutomationItem(id: id, link: "https://example.com/\(id)", body: "\(id) の本文", time: now)
  }

  private func origin(_ id: String) -> AutomationOrigin {
    AutomationOrigin(part: "f", item: item(id))
  }

  /// 取得の部品 `f` を出た行。
  private func row(_ id: String) -> AutomationPartRow {
    AutomationPartRow(id: "f:\(id)", text: #"{"id":"f:\#(id)"}"#, origin: origin(id))
  }

  private func printed(_ stdout: String, exit: Int32 = 0, stderr: String = "")
    -> BackgroundRunResult
  {
    BackgroundRunResult(
      commandLine: "run", startedAt: now, endedAt: now, ending: .exited(exit),
      output: .command(
        stdout: .init(data: Data(stdout.utf8)), stderr: .init(data: Data(stderr.utf8))))
  }

  private func fetched(_ ids: [String]) -> BackgroundRunResult {
    printed(
      ids.map {
        #"{"id":"\#($0)","link":"https://example.com/\#($0)","body":"\#($0) の本文","time":"2026-10-10T09:00:00Z"}"#
      }.joined(separator: "\n"))
  }

  private func replied(_ text: String) -> BackgroundRunResult {
    BackgroundRunResult(
      commandLine: "claude -p", startedAt: now, endedAt: now, ending: .exited(0),
      output: .agent(reply: BackgroundAgentReply(text: text, isError: false), stderr: .init()))
  }

  private func commandInput(_ index: Int) -> BackgroundInput? {
    guard case .command(_, let input) = jobs.calls[index].job.work else { return nil }
    return input
  }

  private var succeeded: AutomationPartPass.Output? {
    guard case .succeeded(let output, _) = outcomes.first else { return nil }
    return output
  }

  private var failed: String? {
    guard case .failed(let reason, _) = outcomes.first else { return nil }
    return reason
  }

  // MARK: - 起こし方

  /// 上限は部品の経過時間だけで、無出力では打ち切らない——黙って長く考える agent を切らないため。
  func testPartIsLimitedOnlyByItsTimeoutNotBySilence() {
    var part = AutomationGraphTests.agent("r", from: ["f"])
    part.timeoutMinutes = 3

    start(part, .report, .report([]))

    XCTAssertEqual(jobs.calls[0].job.limits.elapsed, 180)
    XCTAssertNil(jobs.calls[0].job.limits.idle)
  }

  /// 前回成功の目印は新着の流れの取得にだけ渡る。今の集合に渡すと前回以降の分だけが取れ、取得から消えたものとして候補が下がる。
  func testOnlyNewArrivalsFetchGetsTheMark() throws {
    let since = now.addingTimeInterval(-3600)

    start(
      AutomationGraphTests.fetch("f", .newArrivals), .fetch(.newArrivals),
      .fetch(since: since, lastOutput: []))
    start(
      AutomationGraphTests.fetch("f", .currentSet), .fetch(.currentSet),
      .fetch(since: since, lastOutput: []))

    XCTAssertEqual(
      try XCTUnwrap(commandInput(0)).environment, ["ORBE_SINCE": SessionEvent.iso8601(since)])
    XCTAssertEqual(try XCTUnwrap(commandInput(1)).environment, [:])
  }

  /// 副作用のコマンドは取った行を 1 行 1 オブジェクトで標準入力に受け、回の ID を `ORBE_RUN_ID` で受ける。
  func testSideEffectCommandReceivesRowsOnStdinAndTheRunId() throws {
    start(
      AutomationGraphTests.command("s", from: ["f"]), .sideEffect,
      .sideEffect([row("a"), row("b")], runId: "7-s-1"))

    let input = try XCTUnwrap(commandInput(0))
    XCTAssertEqual(input.stdin, Data("{\"id\":\"f:a\"}\n{\"id\":\"f:b\"}\n".utf8))
    XCTAssertEqual(input.environment, ["ORBE_RUN_ID": "7-s-1"])
  }

  func testWorkAgentRunsWithItsTools() throws {
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    guard case .agent(let call) = jobs.calls[0].job.work else { return XCTFail("仕事は agent") }
    XCTAssertEqual(call.tools, [Self.tool])
  }

  // MARK: - 取得

  /// 前回の出力に無い項目だけを渡す。渡す行の `id` は `<鍵>:<元の id>`、出どころは元の項目のまま。前回の出力は今回の全項目。
  func testFetchPassesOnlyItemsMissingFromTheLastOutput() throws {
    start(
      AutomationGraphTests.fetch("f"), .fetch(.currentSet), .fetch(since: nil, lastOutput: ["a"]))

    jobs.finish(0, fetched(["a", "b"]))

    guard case .fetch(let rows, let lastOutput) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:b"])
    XCTAssertEqual(rows.map { AutomationPrompts.id(of: $0.text) }, ["f:b"])
    XCTAssertEqual(rows.first?.origin?.part, "f")
    XCTAssertEqual(rows.first?.origin?.item.id, "b", "前回の出力と照らせるよう、出どころの id は接頭の無い元の id")
    XCTAssertEqual(
      lastOutput,
      [
        AutomationSeen(id: "a", link: "https://example.com/a"),
        AutomationSeen(id: "b", link: "https://example.com/b"),
      ])
  }

  func testEverythingFetchPassesAllItemsRegardlessOfTheLastOutput() throws {
    start(
      AutomationGraphTests.fetch("f", .everything), .fetch(.everything),
      .fetch(since: nil, lastOutput: ["a"]))

    jobs.finish(0, fetched(["a", "b"]))

    guard case .fetch(let rows, _) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:a", "f:b"])
  }

  /// ツールが揃わず止まった取得は失敗——0 件と読むと、今の集合の候補が一斉に下がる。
  func testFetchThatCouldNotGetItsToolsFails() throws {
    start(
      AutomationGraphTests.agent(
        "f", tools: [Self.tool], deliver: .nextPart, coverage: .currentSet),
      .fetch(.currentSet), .fetch(since: nil, lastOutput: ["a"]))

    jobs.finish(
      0,
      BackgroundRunResult(
        commandLine: "claude -p", startedAt: now, endedAt: now,
        ending: .toolsUnavailable([Self.tool]), output: .agent(reply: nil, stderr: .init())))

    XCTAssertNotNil(failed, "\(outcomes)")
  }

  // MARK: - 処理

  /// 出力の行は `id` で入力の行と照らして出どころを引き継ぎ、照らせない行は出どころを持たない。
  func testProcessCarriesTheOriginById() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a"), row("b")]))

    jobs.finish(0, replied(#"{"id":"f:b","note":"x"}"# + "\n" + #"{"id":"new"}"#))

    guard case .process(let rows) = try XCTUnwrap(succeeded, "\(outcomes)") else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(rows.map(\.id), ["f:b", "new"])
    XCTAssertEqual(rows.map(\.origin), [origin("b"), nil])
  }

  /// `id` の無い行が 1 行でもあれば、その回は失敗で何も渡さない——その行だけ捨てると、捨てた分に気づけない。
  func testProcessOutputWithARowWithoutIdFailsAndPassesNothing() throws {
    start(
      AutomationGraphTests.agent("p", from: ["f"], deliver: .nextPart), .process,
      .process([row("a"), row("b")]))

    jobs.finish(0, replied(#"{"id":"f:a"}"# + "\n" + #"{"note":"id を落とした"}"#))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("line 2"), "定義を直せるよう、どの行かを言う")
  }

  // MARK: - 判定

  /// 候補の案には指した行の出どころが付く。取った行に無い `id` を指す案は理由付きで捨てる。
  func testJudgeProposalsCarryTheOriginOfTheRowTheyPointTo() throws {
    let rows = ["a", "b"].map {
      AutomationSourcedRow(id: "f:\($0)", text: #"{"id":"f:\#($0)"}"#, origin: origin($0))
    }
    start(
      AutomationGraphTests.agent("j", from: ["f"], deliver: .taskCandidates), .judge,
      .judge(
        rows,
        choices: AutomationJudgeChoices(
          open: [], workspaces: AutomationWorkspaces(listed: [], home: nil))))

    jobs.finish(
      0,
      replied(
        #"{"propose":"f:b","title":"b に返信する"}"# + "\n" + #"{"propose":"f:z","title":"z"}"#))

    guard case .judge(let proposals, _, let rejected) = try XCTUnwrap(succeeded, "\(outcomes)")
    else {
      return XCTFail("\(outcomes)")
    }
    XCTAssertEqual(
      proposals,
      [AutomationPartPass.Proposal(origin: origin("b"), title: "b に返信する", due: nil, workspace: nil)]
    )
    XCTAssertEqual(rejected.count, 1)
  }

  // MARK: - 仕事・副作用

  /// 応答が `{"error": …}` の 1 行だけなら、仕事は失敗。
  func testWorkReplyThatIsOnlyAnErrorFails() throws {
    start(AutomationGraphTests.agent("w", tools: [Self.tool]), .work, .work)

    jobs.finish(0, replied(#"{"error":"投稿できなかった"}"#))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("投稿できなかった"))
  }

  /// 副作用は終了コードで成否が決まり、失敗には標準エラーが添えられる。
  func testSideEffectFailsByItsExitCode() throws {
    start(
      AutomationGraphTests.command("s", from: ["f"]), .sideEffect,
      .sideEffect([row("a")], runId: "7-s-1"))

    jobs.finish(0, printed("", exit: 1, stderr: "rate limited"))

    XCTAssertTrue(try XCTUnwrap(failed, "\(outcomes)").contains("rate limited"))
  }

  // MARK: - 止める

  /// 止めた回は、手段が後から終わっても結果を返さない。
  func testStoppedPassNeverReturnsAResult() {
    let handle = start(
      AutomationGraphTests.fetch("f"), .fetch(.currentSet), .fetch(since: nil, lastOutput: []))

    handle.stop()
    jobs.finish(0, fetched(["a"]))

    XCTAssertEqual(jobs.stopped, [0])
    XCTAssertEqual(outcomes, [])
  }
}

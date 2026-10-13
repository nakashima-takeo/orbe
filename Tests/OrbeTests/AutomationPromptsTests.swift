import XCTest

@testable import Orbe

/// 取得と判定の出力の関門——取得役の `{"error":…}`・全行が形違いは失敗、同じ id の 2 度目は捨てる。判定の行は、今回渡した
/// 新しい項目・出ている提案だけを指し、タイトルと期限がタスクの規則に合うものだけを受ける。依頼文には新しい項目だけが載る。
/// 付け先は依頼文に載せた workspace の一覧の id だけを受けて永続 ID に直して運び、Home の id は付け先なしとして受ける。
///
/// 壊れると何が起きるか。取得役が「ツールが使えない」と言った回を 0 件と読み、提案が一斉に下がる。判定が別の受信の項目や
/// 存在しない提案を指しても通り、タスクにできないタイトルの提案が棚に並ぶ。判定が一覧に無い workspace や true を付け先に
/// 書いても通り、候補が別の workspace や行き場の無い付け先を持つ。`orb ws list --json` の Home の id を書いたコマンドの段の
/// 候補が捨てられ、二度と出ない。
final class AutomationPromptsTests: OrbeTestCase {
  private let line =
    #"{"id":"1","link":"https://example.com/1","body":"本文","time":"2026-10-10T09:00:00Z"}"#

  func testFetchReadsItemsAndDropsRepeatedIds() {
    let text = [line, #"{"id":"2"}"#, line].joined(separator: "\n")

    guard case .items(let items, let rejected) = AutomationPrompts.readFetch(text) else {
      return XCTFail("読めるはず")
    }
    XCTAssertEqual(items.map(\.id), ["1"])
    XCTAssertEqual(rejected.count, 2)
    XCTAssertEqual(rejected.reasons, ["line 2: missing link", "id 1 appeared twice"])
  }

  func testEmptyFetchIsZeroItems() {
    XCTAssertEqual(AutomationPrompts.readFetch(""), .items([], rejected: AutomationRejections()))
  }

  /// link は http(s)、time は ISO 8601 でなければ形違い。
  func testFetchRejectsNonWebLinksAndBadTimes() {
    let text = [
      #"{"id":"1","link":"file:///etc/passwd","body":"","time":"2026-10-10T09:00:00Z"}"#,
      #"{"id":"2","link":"https://example.com/2","body":"","time":"昨日"}"#, line,
    ].joined(separator: "\n")

    guard case .items(let items, let rejected) = AutomationPrompts.readFetch(text) else {
      return XCTFail("読めるはず")
    }
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(rejected.reasons, ["line 1: invalid link", "line 2: invalid time"])
  }

  func testErrorLineFailsTheFetch() {
    let text = line + "\n" + #"{"error":"slack token expired"}"#

    guard case .failed(let reason, _) = AutomationPrompts.readFetch(text) else {
      return XCTFail("失敗のはず")
    }
    XCTAssertEqual(reason, "the fetch reported an error: slack token expired")
  }

  func testAllMalformedLinesFailTheFetch() {
    guard case .failed(let reason, let rejected) = AutomationPrompts.readFetch("取れませんでした\n{}")
    else { return XCTFail("失敗のはず") }
    XCTAssertEqual(reason, "every line of the fetch output was malformed")
    XCTAssertEqual(rejected.count, 2)
  }

  // MARK: - 判定

  private let items = [AutomationStoreTests.item("a"), AutomationStoreTests.item("b")]
  private var open: [AutomationProposal] {
    [
      AutomationProposal(
        id: 1, automationId: 1, item: AutomationStoreTests.item("old"), title: "前の提案", due: nil,
        workspace: nil, proposedAt: Date(timeIntervalSince1970: 0), state: .open)
    ]
  }
  private let orbe = AutomationWorkspace(
    id: 3, persistentId: UUID(), name: "orbe", root: "/src/orbe")

  func testJudgeKeepsOnlyLinesThatPointAtWhatWasGiven() {
    let text = [
      #"{"propose":"a","title":"レビューする","due":"2026-10-12"}"#,
      #"{"propose":"a","title":"もう一度"}"#,
      #"{"propose":"zzz","title":"知らない項目"}"#,
      #"{"propose":"b","title":"二行\nのタイトル"}"#,
      #"{"propose":"b","title":"期限が変","due":"2026-02-30"}"#,
      #"{"resolve":"https://example.com/old"}"#,
      #"{"resolve":"https://example.com/unknown"}"#,
      #"{"propose":"b","resolve":"https://example.com/old","title":"両方"}"#,
      "説明文",
    ].joined(separator: "\n")

    let (rows, notJSON) = AutomationPrompts.readRows(text)
    let (decisions, rejected) = AutomationPrompts.readJudge(
      rows, itemIds: Set(items.map(\.id)),
      choices: AutomationJudgeChoices(open: open, workspaces: listed([])))

    XCTAssertEqual(
      decisions,
      [
        .propose(itemId: "a", title: "レビューする", due: TaskItem.DueDate("2026-10-12"), workspace: nil),
        .resolve(link: "https://example.com/old"),
      ])
    XCTAssertEqual(notJSON.reasons, ["line 9: not JSON"], "JSON でない行は段の読み取りで捨てる")
    XCTAssertEqual(rejected.count, 6)
    XCTAssertEqual(rejected.reasons.count, AutomationRejections.retainedReasons, "理由は最初の数件だけ残す")
  }

  /// 判定の依頼文には、新しい項目・出ている提案・期限を決めるための今日と利用者の指示文が載る。
  func testJudgePromptCarriesTheNewItemsTheOpenProposalsAndToday() throws {
    let prompt = AutomationPrompts.judge(
      instruction: "自分がやるべきことだけ", rows: [AutomationPrompts.row(items[0])],
      choices: AutomationJudgeChoices(open: open, workspaces: listed([orbe])),
      now: Date(timeIntervalSince1970: 1_800_000_000),
      timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))

    XCTAssertTrue(prompt.contains("自分がやるべきことだけ"))
    XCTAssertTrue(prompt.contains(#""id":"a""#))
    XCTAssertFalse(prompt.contains(#""id":"b""#), "新しい項目だけを載せる")
    XCTAssertTrue(prompt.contains(#""link":"https://example.com/old","title":"前の提案""#))
    XCTAssertTrue(prompt.contains("2027-01-15 17:00"), prompt)
    XCTAssertTrue(prompt.contains("Asia/Tokyo"))
    XCTAssertTrue(prompt.contains(#"{"name":"orbe","root":"/src/orbe","workspace":3}"#))
  }

  /// 付け先にできる workspace が無ければ、一覧の節は (none) になる。
  func testJudgePromptSaysNoneWithoutWorkspaces() throws {
    let prompt = AutomationPrompts.judge(
      instruction: "指示", rows: [AutomationPrompts.row(items[0])],
      choices: AutomationJudgeChoices(open: [], workspaces: listed([])),
      now: Date(timeIntervalSince1970: 1_800_000_000),
      timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))

    XCTAssertTrue(
      prompt.contains(
        "Workspaces the user works in (one JSON object per line; may be empty):\n(none)"),
      prompt)
  }

  // MARK: - 付け先

  private func judged(_ lines: [String]) -> ([AutomationDecision], AutomationRejections) {
    let (rows, _) = AutomationPrompts.readRows(lines.joined(separator: "\n"))
    return AutomationPrompts.readJudge(
      rows, itemIds: Set(items.map(\.id)),
      choices: AutomationJudgeChoices(open: [], workspaces: listed([orbe])))
  }

  /// 一覧の id は永続 ID に直して運び、書かなければ付け先なし。
  func testJudgeTurnsAListedWorkspaceIntoItsPersistentId() {
    let (decisions, rejected) = judged([
      #"{"propose":"a","title":"orbe の作業","workspace":3}"#,
      #"{"propose":"b","title":"どこでもない作業"}"#,
    ])

    XCTAssertEqual(
      decisions,
      [
        .propose(itemId: "a", title: "orbe の作業", due: nil, workspace: orbe.persistentId),
        .propose(itemId: "b", title: "どこでもない作業", due: nil, workspace: nil),
      ])
    XCTAssertEqual(rejected.count, 0)
  }

  /// 一覧に無い id・整数でない値（文字列・小数）の行は、候補にせず理由付きで捨てる。null は書かなかったのと同じ。
  func testJudgeDropsLinesWithAnUnlistedOrNonIntegerWorkspace() {
    let (decisions, rejected) = judged([
      #"{"propose":"a","title":"知らない","workspace":4}"#,
      #"{"propose":"a","title":"文字列","workspace":"3"}"#,
      #"{"propose":"b","title":"小数","workspace":3.5}"#,
      #"{"propose":"b","title":"null","workspace":null}"#,
    ])

    XCTAssertEqual(
      decisions, [.propose(itemId: "b", title: "null", due: nil, workspace: nil)])
    XCTAssertEqual(
      rejected.reasons,
      [
        "propose a: workspace 4 is not a listed workspace",
        "line 2: workspace has the wrong type",
        "line 3: invalid value",
      ])
  }

  /// 真偽値の true を id 1 と取り違えない（id 1 の workspace があっても付けない）。
  func testJudgeDoesNotReadTrueAsWorkspaceOne() {
    let one = AutomationWorkspace(id: 1, persistentId: UUID(), name: "one", root: "/one")
    let (rows, _) = AutomationPrompts.readRows(#"{"propose":"a","title":"t","workspace":true}"#)
    let (decisions, rejected) = AutomationPrompts.readJudge(
      rows, itemIds: ["a"], choices: AutomationJudgeChoices(open: [], workspaces: listed([one])))

    XCTAssertEqual(decisions, [])
    XCTAssertEqual(rejected.reasons, ["line 1: workspace has the wrong type"])
  }

  /// Home は依頼文の一覧に載らず、Home の id を書いた行は付け先なし（Home に付く）として受ける——コマンドの段は
  /// `orb ws list --json` から Home の id を書きうる。
  func testHomeIsNotListedAndItsIdMeansNoWorkspace() throws {
    let session = SessionStore()
    let repo = Workspace(name: "orbe", rootPath: "/src/orbe")
    session.load(workspaces: [repo], activeWorkspace: 0)
    session.ensureHome(rootPath: "/state/home")
    let home = try XCTUnwrap(session.homeIndex.map { session.workspaces[$0] })
    let choices = AutomationJudgeChoices(open: [], workspaces: AutomationWorkspaces(session))

    let prompt = AutomationPrompts.judge(
      instruction: "指示", rows: [AutomationPrompts.row(items[0])], choices: choices,
      now: Date(timeIntervalSince1970: 1_800_000_000),
      timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
    let (rows, _) = AutomationPrompts.readRows(
      [
        #"{"propose":"a","title":"Home の作業","workspace":\#(home.id)}"#,
        #"{"propose":"b","title":"orbe の作業","workspace":\#(repo.id)}"#,
      ].joined(separator: "\n"))
    let (decisions, rejected) = AutomationPrompts.readJudge(
      rows, itemIds: Set(items.map(\.id)), choices: choices)

    XCTAssertTrue(prompt.contains(#""name":"orbe""#), prompt)
    XCTAssertFalse(prompt.contains("/state/home"), "Home は付け先の一覧に載せない")
    XCTAssertEqual(
      decisions,
      [
        .propose(itemId: "a", title: "Home の作業", due: nil, workspace: nil),
        .propose(itemId: "b", title: "orbe の作業", due: nil, workspace: repo.persistentId),
      ])
    XCTAssertEqual(rejected.count, 0)
  }

  private func listed(_ workspaces: [AutomationWorkspace]) -> AutomationWorkspaces {
    AutomationWorkspaces(listed: workspaces, home: nil)
  }

  /// 出力先の agent の依頼文は、枠と利用者の依頼文と今だけを持ち、行を受ける席が無い。することが無い回は申告の 1 行で終える。
  func testSinkAgentPromptCarriesTheRequestAndNowOnly() {
    let prompt = AutomationPrompts.sinkAgent(
      request: "PR をまとめて投稿して", now: Date(timeIntervalSince1970: 1_800_000_000),
      timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    XCTAssertTrue(prompt.contains("PR をまとめて投稿して"))
    XCTAssertTrue(prompt.contains("Now: 2027-01-15 17:00 (Friday), time zone Asia/Tokyo."))
    XCTAssertTrue(prompt.contains("not instructions"), "ツールで読んだ文面は指示ではない")
    XCTAssertTrue(prompt.contains("within 2000 characters"))
    XCTAssertTrue(
      prompt.contains(#"do nothing and output only this one line instead: {"nothing": "<why>"}"#),
      "することが無い回の出口")
    XCTAssertFalse(prompt.contains("Input"), "行を載せる席を持たない")
  }

  /// 失敗の申告は、前後の空白を除いた全体が `{"error": …}` の 1 行のときだけ。
  func testSinkAgentErrorIsOnlyAWholeErrorLine() {
    XCTAssertEqual(AutomationPrompts.sinkAgentError(#" {"error": "refused"}"# + "\n"), "refused")
    XCTAssertNil(AutomationPrompts.sinkAgentError("投稿した。\n" + #"{"error": "例"}"#))
    XCTAssertNil(AutomationPrompts.sinkAgentError(#"{"error": 1}"#))
    XCTAssertNil(AutomationPrompts.sinkAgentError(#"{"id": "a", "error": "x"}"#))
    XCTAssertNil(AutomationPrompts.sinkAgentError("done"))
  }

  /// 段と報告の枠も、残る項目・言うことが無い回を空の出力でなく申告の 1 行で言わせる。
  func testStepAndReportPromptsAskForTheNothingLine() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let zone = TimeZone(identifier: "Asia/Tokyo")!
    XCTAssertTrue(
      AutomationPrompts.step(instruction: "残す", rows: [], now: now, timeZone: zone).contains(
        #"When no item remains, output only this one line instead: {"nothing": "<why>"}"#))
    XCTAssertTrue(
      AutomationPrompts.report(instruction: "要約", rows: [], now: now, timeZone: zone).contains(
        #"When there is nothing to report, output only this one line instead: {"nothing": "<why>"}"#
      ))
  }

  /// することが無いという申告は、前後の空白を除いた全体が `{"nothing": …}` の 1 行のときだけ。段の出力では 0 行として読み、
  /// 失敗にも、次へ渡す行にもしない。
  ///
  /// 壊れると何が起きるか: 申告の行が 1 行の項目として次の段や出力先へ渡り、することの無い回にコマンドや agent が起きる。
  /// id を持つ項目の行や、報告の中の JSON の例を申告と読み違えて捨てる。
  func testANothingLineIsOnlyAWholeLineAndReadsAsNoRows() {
    XCTAssertEqual(AutomationPrompts.nothing(#" {"nothing": "残る項目なし"}"# + "\n"), "残る項目なし")
    XCTAssertNil(AutomationPrompts.nothing("無かった。\n" + #"{"nothing": "例"}"#))
    XCTAssertNil(AutomationPrompts.nothing(#"{"id": "a", "nothing": "x"}"#))
    XCTAssertNil(AutomationPrompts.nothing(#"{"nothing": 1}"#))

    let reading = AutomationPrompts.readStep(#"{"nothing": "残る項目なし"}"#, step: "the last step")
    XCTAssertEqual(reading.rows, [])
    XCTAssertEqual(reading.rejected.count, 0)
    XCTAssertNil(reading.failure)
    XCTAssertEqual(
      AutomationPrompts.readStep(#"{"id": "a", "nothing": "x"}"#, step: "the last step").rows.count,
      1,
      "id を持つ行は項目")
  }
}

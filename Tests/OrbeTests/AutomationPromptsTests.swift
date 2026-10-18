import XCTest

@testable import Orbe

/// 依頼文の枠と出力の行の関門——取得の項目は link が http(s)、time が ISO 8601 のものだけ。判定の行は、今回渡した項目・出ている
/// 提案だけを指し、タイトルと期限がタスクの規則に合うものだけを受ける。依頼文には渡した項目だけが載る。付け先は依頼文に載せた
/// workspace の一覧の id だけを受けて永続 ID に直して運び、Home の id は付け先なしとして受ける。
///
/// 壊れると何が起きるか。外の文面の file: の link が候補のリンクになる。判定が別の自動化の項目や
/// 存在しない提案を指しても通り、タスクにできないタイトルの提案が棚に並ぶ。判定が一覧に無い workspace や true を付け先に
/// 書いても通り、候補が別の workspace や行き場の無い付け先を持つ。`orb ws list --json` の Home の id を書いたコマンドの判定の
/// 候補が捨てられ、二度と出ない。
final class AutomationPromptsTests: OrbeTestCase {
  private let line =
    #"{"id":"1","link":"https://example.com/1","body":"本文","time":"2026-10-10T09:00:00Z"}"#

  /// link は http(s)、time は ISO 8601 でなければ形違い。
  func testFetchRejectsNonWebLinksAndBadTimes() {
    let text = [
      #"{"id":"1","link":"file:///etc/passwd","body":"","time":"2026-10-10T09:00:00Z"}"#,
      #"{"id":"2","link":"https://example.com/2","body":"","time":"昨日"}"#, line,
    ].joined(separator: "\n")

    let read = JSONLines<AutomationItem>(text)
    XCTAssertEqual(read.items.count, 1)
    XCTAssertEqual(
      read.rejected.map { "line \($0.line): \($0.reason.text)" },
      ["line 1: invalid link", "line 2: invalid time"])
  }

  // MARK: - 判定

  private static func item(_ id: String) -> AutomationItem {
    AutomationItem(
      id: id, link: "https://example.com/\(id)", body: "\(id) の本文",
      time: Date(timeIntervalSince1970: 1_800_000_000))
  }

  private let items = [item("a"), item("b")]
  private var open: [AutomationProposal] {
    [
      AutomationProposal(
        id: 1, automationId: 1, partKey: "judge", sourcePartKey: "f", item: Self.item("old"),
        title: "前の提案", due: nil, workspace: nil, reason: nil,
        proposedAt: Date(timeIntervalSince1970: 0),
        state: .open)
    ]
  }

  /// 判定の出力を行ごとに読んだもの。受けなかった行は判定の部品の読みと同じく「line <n>: <理由>」で持ち、JSON でない行は
  /// 別に持つ。
  private struct Read {
    let decisions: [AutomationDecision]
    let rejected: [String]
    let notJSON: [String]
  }

  private func read(_ text: String, itemIds: Set<String>, choices: AutomationJudgeChoices) -> Read {
    let (rows, broken) = AutomationPrompts.objectRows(text)
    var decisions: [AutomationDecision] = []
    var rejected: [String] = []
    for reading in AutomationPrompts.judgeRows(rows, itemIds: itemIds, choices: choices) {
      switch reading {
      case .success(let decision): decisions.append(decision)
      case .failure(let line): rejected.append(line.text)
      }
    }
    return Read(decisions: decisions, rejected: rejected, notJSON: broken.map(\.text))
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

    let read = read(
      text, itemIds: Set(items.map(\.id)),
      choices: AutomationJudgeChoices(open: open, workspaces: listed([])))
    let (decisions, rejected, notJSON) = (read.decisions, read.rejected, read.notJSON)

    XCTAssertEqual(
      decisions,
      [
        .propose(
          itemId: "a", title: "レビューする", due: TaskItem.DueDate("2026-10-12"), workspace: nil,
          reason: nil),
        .resolve(link: "https://example.com/old"),
      ])
    XCTAssertEqual(notJSON, ["line 9: not JSON"], "JSON でない行は行の読み取りで外す")
    XCTAssertEqual(
      rejected,
      [
        "line 2: propose a: proposed twice", "line 3: propose zzz: not a new item",
        "line 4: propose b: title must be a single non-empty line",
        "line 5: propose b: due is not a YYYY-MM-DD date: 2026-02-30",
        "line 7: resolve https://example.com/unknown: not a waiting proposal",
        "line 8: a line must have exactly one of propose / resolve",
      ], "どの行も行番号付きの理由で外す")
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

  private func judged(_ lines: [String]) -> ([AutomationDecision], [String]) {
    let read = read(
      lines.joined(separator: "\n"), itemIds: Set(items.map(\.id)),
      choices: AutomationJudgeChoices(open: [], workspaces: listed([orbe])))
    return (read.decisions, read.rejected)
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
        .propose(
          itemId: "a", title: "orbe の作業", due: nil, workspace: orbe.persistentId, reason: nil),
        .propose(itemId: "b", title: "どこでもない作業", due: nil, workspace: nil, reason: nil),
      ])
    XCTAssertEqual(rejected, [])
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
      decisions, [.propose(itemId: "b", title: "null", due: nil, workspace: nil, reason: nil)])
    XCTAssertEqual(
      rejected,
      [
        "line 1: propose a: workspace 4 is not a listed workspace",
        "line 2: workspace has the wrong type",
        "line 3: invalid value",
      ])
  }

  /// 真偽値の true を id 1 と取り違えない（id 1 の workspace があっても付けない）。
  func testJudgeDoesNotReadTrueAsWorkspaceOne() {
    let one = AutomationWorkspace(id: 1, persistentId: UUID(), name: "one", root: "/one")
    let read = read(
      #"{"propose":"a","title":"t","workspace":true}"#, itemIds: ["a"],
      choices: AutomationJudgeChoices(open: [], workspaces: listed([one])))
    let (decisions, rejected) = (read.decisions, read.rejected)

    XCTAssertEqual(decisions, [])
    XCTAssertEqual(rejected, ["line 1: workspace has the wrong type"])
  }

  /// Home は依頼文の一覧に載らず、Home の id を書いた行は付け先なし（Home に付く）として受ける——コマンドの判定は
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
    let read = read(
      [
        #"{"propose":"a","title":"Home の作業","workspace":\#(home.id)}"#,
        #"{"propose":"b","title":"orbe の作業","workspace":\#(repo.id)}"#,
      ].joined(separator: "\n"), itemIds: Set(items.map(\.id)), choices: choices)
    let (decisions, rejected) = (read.decisions, read.rejected)

    XCTAssertTrue(prompt.contains(#""name":"orbe""#), prompt)
    XCTAssertFalse(prompt.contains("/state/home"), "Home は付け先の一覧に載せない")
    XCTAssertEqual(
      decisions,
      [
        .propose(itemId: "a", title: "Home の作業", due: nil, workspace: nil, reason: nil),
        .propose(
          itemId: "b", title: "orbe の作業", due: nil, workspace: repo.persistentId, reason: nil),
      ])
    XCTAssertEqual(rejected, [])
  }

  private func listed(_ workspaces: [AutomationWorkspace]) -> AutomationWorkspaces {
    AutomationWorkspaces(listed: workspaces, home: nil)
  }

  /// 仕事の依頼文は、枠と利用者の依頼文と今だけを持ち、行を受ける席が無い。することが無い回は申告の 1 行で終える。
  func testWorkPromptCarriesTheRequestAndNowOnly() {
    let prompt = AutomationPrompts.work(
      instruction: "PR をまとめて投稿して", now: Date(timeIntervalSince1970: 1_800_000_000),
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
  func testWorkErrorIsOnlyAWholeErrorLine() {
    XCTAssertEqual(AutomationPrompts.workError(#" {"error": "refused"}"# + "\n"), "refused")
    XCTAssertNil(AutomationPrompts.workError("投稿した。\n" + #"{"error": "例"}"#))
    XCTAssertNil(AutomationPrompts.workError(#"{"error": 1}"#))
    XCTAssertNil(AutomationPrompts.workError(#"{"id": "a", "error": "x"}"#))
    XCTAssertNil(AutomationPrompts.workError("done"))
  }

  /// 処理と報告の枠も、残る項目・言うことが無い回を空の出力でなく申告の 1 行で言わせる。
  func testProcessAndReportPromptsAskForTheNothingLine() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let zone = TimeZone(identifier: "Asia/Tokyo")!
    XCTAssertTrue(
      AutomationPrompts.process(
        instruction: "残す", rows: [], now: now, timeZone: zone, reachesJudge: false
      ).contains(
        #"When no item remains, output only this one line instead: {"nothing": "<why>"}"#))
    XCTAssertTrue(
      AutomationPrompts.report(instruction: "要約", rows: [], now: now, timeZone: zone).contains(
        #"When there is nothing to report, output only this one line instead: {"nothing": "<why>"}"#
      ))
  }

  /// することが無いという申告は、最後の空でない行が `{"nothing": …}` のとき。前置きの文は捨てる（モデルが前置きの後に申告を
  /// 付けることがある）。申告の後に文が続く出力・`id` を持つ行は申告でない。
  func testANothingLineIsTheLastNonEmptyLine() {
    XCTAssertEqual(AutomationPrompts.nothing(#" {"nothing": "残る項目なし"}"# + "\n"), "残る項目なし")
    XCTAssertEqual(
      AutomationPrompts.nothing("今日は水曜日です。\n\n" + #"{"nothing": "日曜でない"}"# + "\n  \n"), "日曜でない")
    XCTAssertNil(AutomationPrompts.nothing(#"{"nothing": "例"}"# + "\n投稿した。"))
    XCTAssertNil(AutomationPrompts.nothing(#"{"id": "a", "nothing": "x"}"#))
    XCTAssertNil(AutomationPrompts.nothing(#"{"nothing": 1}"#))
  }
}

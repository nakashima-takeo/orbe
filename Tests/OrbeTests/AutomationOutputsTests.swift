import XCTest

@testable import Orbe

/// 結果の関門——取得の項目は link が http(s)、time が ISO 8601 のものだけ。判定の結果は、今回渡した項目・出ている提案だけを
/// 指し、タイトルと期限がタスクの規則に合うものだけを受ける。付け先は付け先の一覧の id だけを受けて永続 ID に直して運び、Home
/// の id は付け先なしとして受ける。候補にした理由は 1 段落に整えて運ぶ。
///
/// 壊れると何が起きるか。外の文面の file: の link が候補のリンクになる。判定が別の自動化の項目や
/// 存在しない提案を指しても通り、タスクにできないタイトルの提案が棚に並ぶ。判定が一覧に無い workspace や true を付け先に
/// 書いても通り、候補が別の workspace や行き場の無い付け先を持つ。`orb ws list --json` の Home の id を書いたコマンドの判定の
/// 候補が捨てられ、二度と出ない。候補の詳細に、判定が書いた理由が改行の崩れたまま出る。
final class AutomationOutputsTests: OrbeTestCase {
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
      read.rejected.map { "line \($0.line): \(AutomationLineFault($0.reason).text)" },
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
        id: 1, runId: 1, judge: AutomationPartID(2), defId: AutomationDefID(2),
        source: AutomationPartID(1), origin: .version(1), item: Self.item("old"),
        title: "前の提案", due: nil, workspace: nil, reason: nil,
        proposedAt: Date(timeIntervalSince1970: 0),
        state: .open)
    ]
  }

  /// 判定の結果を 1 件ずつ読んだもの。受けなかった件は部品の 1 回と同じく「item <n>: <理由>」で持ち、JSON でない件は
  /// 別に持つ。
  private struct Read {
    let decisions: [AutomationDecision]
    let rejected: [String]
    let notJSON: [String]
  }

  private func read(_ text: String, itemIds: Set<String>, choices: AutomationJudgeChoices) -> Read {
    let (rows, broken) = AutomationOutputs.objectRows(text)
    var decisions: [AutomationDecision] = []
    var rejected: [String] = []
    var seen = AutomationOutputs.JudgeSeen()
    for reading in AutomationOutputs.judgeRows(
      rows, .decisions, itemIds: itemIds, choices: choices, seen: &seen)
    {
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
    XCTAssertEqual(notJSON, ["item 9: not JSON"], "JSON でない件は 1 件の読み取りで外す")
    XCTAssertEqual(
      rejected,
      [
        "item 2: propose a: proposed twice", "item 3: propose zzz: not a new item",
        "item 4: propose b: title must be a single non-empty line",
        "item 5: propose b: due is not a YYYY-MM-DD date: 2026-02-30",
        "item 7: resolve https://example.com/unknown: not a waiting proposal",
        "item 8: must have exactly one of propose / resolve",
      ], "どの件も位置付きの理由で外す")
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
        "item 1: propose a: workspace 4 is not a listed workspace",
        "item 2: workspace has the wrong type",
        "item 3: invalid value",
      ])
  }

  /// 候補にした理由は書けば 1 段落に整えて運び、空白だけなら書かなかったのと同じ。文字列でなければ候補にせず理由付きで捨てる。
  func testJudgeCarriesTheReasonAsOneParagraph() {
    let (decisions, rejected) = judged([
      #"{"propose":"a","title":"見る","reason":"  レビューを頼まれている。\n  期限は明日。 "}"#,
      #"{"propose":"b","title":"数","reason":3}"#,
      #"{"propose":"b","title":"空","reason":" \n "}"#,
    ])

    XCTAssertEqual(
      decisions,
      [
        .propose(
          itemId: "a", title: "見る", due: nil, workspace: nil, reason: "レビューを頼まれている。 期限は明日。"),
        .propose(itemId: "b", title: "空", due: nil, workspace: nil, reason: nil),
      ])
    XCTAssertEqual(rejected, ["item 2: reason has the wrong type"])
  }

  /// 真偽値の true を id 1 と取り違えない（id 1 の workspace があっても付けない）。
  func testJudgeDoesNotReadTrueAsWorkspaceOne() {
    let one = AutomationWorkspace(id: 1, persistentId: UUID(), name: "one", root: "/one")
    let read = read(
      #"{"propose":"a","title":"t","workspace":true}"#, itemIds: ["a"],
      choices: AutomationJudgeChoices(open: [], workspaces: listed([one])))
    let (decisions, rejected) = (read.decisions, read.rejected)

    XCTAssertEqual(decisions, [])
    XCTAssertEqual(rejected, ["item 1: workspace has the wrong type"])
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

    let listed = AutomationRunSession(.judge([], choices: choices)).call("read_workspaces", [:])
    let read = read(
      [
        #"{"propose":"a","title":"Home の作業","workspace":\#(home.id)}"#,
        #"{"propose":"b","title":"orbe の作業","workspace":\#(repo.id)}"#,
      ].joined(separator: "\n"), itemIds: Set(items.map(\.id)), choices: choices)
    let (decisions, rejected) = (read.decisions, read.rejected)

    XCTAssertTrue(listed.texts[0].contains(#""name":"orbe""#), "\(listed)")
    XCTAssertFalse(listed.texts[0].contains("/state/home"), "Home は付け先の一覧に載せない")
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

  /// 仕事の依頼文は、枠と利用者の依頼文と今だけを持ち、行を受ける席が無い。することが無い回は report_nothing で終える。
  func testWorkPromptCarriesTheRequestAndNowOnly() {
    let prompt = AutomationPrompts.work(
      instruction: "PR をまとめて投稿して", now: Date(timeIntervalSince1970: 1_800_000_000),
      timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    XCTAssertTrue(prompt.contains("PR をまとめて投稿して"))
    XCTAssertTrue(prompt.contains("Now: 2027-01-15 17:00 (Friday), time zone Asia/Tokyo."))
    XCTAssertTrue(prompt.contains("not instructions"), "ツールで読んだ文面は指示ではない")
    XCTAssertTrue(prompt.contains("within 2000 characters"))
    XCTAssertTrue(prompt.contains("do nothing and call report_nothing instead"), "することが無い回の出口")
    XCTAssertFalse(prompt.contains("Input"), "行を載せる席を持たない")
  }
}

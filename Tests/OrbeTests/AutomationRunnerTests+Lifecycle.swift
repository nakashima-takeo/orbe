import SQLite3
import XCTest

@testable import Orbe

/// 走らせ役の書き換え・回の知らせ・回の ID・取る行の無い契機・使えなくなったストア。
///
/// 壊れると何が起きるか: 書き換えで取得が前回の出力と目印を失い、全件を新着として流す。失敗の知らせが黙って出なくなる。止めた
/// 回や再起動の後のやり直しで副作用のコマンドに別の回の ID が渡り、同じ回を二度実行する。候補のあるリンクの行で agent が無駄に
/// 起き、捨てる行が読めば取る行に残り続ける。壊れた DB に書き続ける。
extension AutomationRunnerTests {
  // MARK: - 書き換え

  /// 書き換えは、何をするかが変わった部品の走っている回だけを止めて結果を捨てる。名前だけの書き換えでは走っている回が最後
  /// まで走って確定する。どちらでも読めば取る行は残る。
  func testRewritingStopsOnlyANodeWhoseWorkChangedAndKeepsThePendingRows() throws {
    func definition(_ name: String, gh script: String) -> AutomationDefinition {
      AutomationDefinition(
        name: name, notify: nil,
        parts: [
          fetch("gh", every: 1800, script: script),
          definitionNode(
            "judge", .scheduled(.every(86400)), from: ["gh"], deliver: .taskCandidates),
        ])
    }
    let id = try runner.set(nil, definition("受信", gh: "gh")).id
    advance(by: 1800)
    finish("gh", fetched(["a"]))

    advance(by: 1800)
    try rewrite(id, definition("受信（改名）", gh: "gh"))
    XCTAssertEqual(jobs.stopped, [], "名前だけなら走っている回を止めない")
    finish("gh", fetched(["a", "b"]))
    XCTAssertEqual(store.automation(id)?.state(key: "gh").runs.count, 2)

    advance(by: 1800)
    let running = try XCTUnwrap(calls("gh").last)
    try rewrite(id, definition("受信（改名）", gh: "gh --all"))
    XCTAssertEqual(jobs.stopped, [running])
    jobs.finish(running, fetched(["a", "b", "c"]))

    XCTAssertEqual(store.automation(id)?.state(key: "gh").runs.count, 2, "止めた回の結果は確定しない")
    XCTAssertEqual(pending("judge", of: id), 2)
    let gh = try XCTUnwrap(store.automation(id)?.state(key: "gh"))
    XCTAssertEqual(try store.lastSeqs(id, "gh").event, 2, "出した行は残る")
    XCTAssertEqual(gh.succeededAt, start.addingTimeInterval(3600), "前回成功の目印は残る")
  }

  /// 既定と同じ上限を書き足しただけの書き換えは、部品の使う定義を付け替えても走っている回を止めない。その回は始めたときの
  /// 定義で確定する——その定義での最初の回で、ほかに指すものが無くても、回が使う定義は確定まで掃除で消えない。
  func testARunningRunSettlesOnItsDefinitionAfterAWriteThatOnlySpellsOutADefault() throws {
    var gh = fetch("gh", every: 1800)
    let digest = definitionNode("digest", .arrival, from: ["gh"], deliver: .report)
    let id = try define([gh, digest])
    let first = try XCTUnwrap(store.automation(id)?.graph.node(key: "gh")?.entity.defId)
    advance(by: 1800)

    gh.action.timeoutMinutes = 2
    try rewrite(id, AutomationDefinition(name: "自動化", notify: nil, parts: [gh, digest]))
    XCTAssertNotEqual(
      store.automation(id)?.graph.node(key: "gh")?.entity.defId, first, "前提: 書き足した値を保存する定義に付け替える")
    XCTAssertEqual(jobs.stopped, [])
    finish("gh", fetched(["a"]))

    let nodeId = store.nodeId(id, "gh")
    XCTAssertEqual(
      try store.read {
        try $0.db.select(
          "SELECT def_id FROM runs WHERE part_id = ?", [.integer(Int64(nodeId.rawValue))]
        ) { AutomationDefID($0.int(at: 0)) }
      }, [first], "回の記録は始めたときの定義を指す")
    XCTAssertEqual(try store.lastSeqs(id, "gh").event, 1)
    XCTAssertEqual(calls("digest").count, 1, "確定した行が下流へ届く")
  }

  /// 回を記録するたびに、その部品の鍵で知らせる（成功でも失敗でも）。止めて結果を捨てた回は知らせない。
  func testEveryRecordedRunIsToldAndAStoppedRunIsNot() throws {
    func definition(gh script: String) -> AutomationDefinition {
      AutomationDefinition(
        name: "要約", notify: nil,
        parts: [
          fetch("gh", every: 1800, script: script),
          definitionNode("digest", .arrival, from: ["gh"], deliver: .report),
        ])
    }
    let id = try runner.set(nil, definition(gh: "gh")).id
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("digest", printed("", exit: 1))
    XCTAssertEqual(recorded, ["gh", "digest"])

    advance(by: 1800)
    let running = try XCTUnwrap(calls("gh").last)
    try rewrite(id, definition(gh: "gh --all"))
    jobs.finish(running, fetched(["a", "b"]))

    XCTAssertEqual(recorded, ["gh", "digest"])
  }

  // MARK: - 回の ID

  /// 副作用の部品に渡す回の ID は、記録の前に止めた回のやり直しでも、再起動の後のやり直しでも同じで、回を記録すると変わる。
  func testTheRunIdStaysForARetryOfAnUnrecordedRunAndMovesWhenARunIsRecorded() throws {
    func definition(post script: String) -> AutomationDefinition {
      AutomationDefinition(
        name: "投稿", notify: nil,
        parts: [
          fetch("gh", every: 1800),
          definitionNode("post", .arrival, from: ["gh"], script: script, deliver: .sideEffect),
        ])
    }
    func runId(_ script: String) -> String? {
      calls(script).last.flatMap { input($0)?.environment["ORBE_RUN_ID"] }
    }
    let id = try runner.set(nil, definition(post: "post")).id
    let post = store.nodeId(id, "post")
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    let first = try XCTUnwrap(runId("post"))

    advance(by: 60)
    try rewrite(id, definition(post: "post --v2"))
    XCTAssertEqual(runId("post --v2"), first, "止めた回のやり直しは同じ ID")
    finish("post --v2", printed(""))
    advance(by: 1800)
    finish("gh", fetched(["a", "b"]))
    let second = try XCTUnwrap(runId("post --v2"))
    XCTAssertNotEqual(second, first, "回を記録したら次の ID")

    let before = calls("post --v2").count
    advance(by: 60)
    launch()
    XCTAssertEqual(calls("post --v2").count, before + 1, "前提: 起動で読めば取る行をやり直す")
    XCTAssertEqual(runId("post --v2"), second, "再起動の後のやり直しも同じ ID")
    XCTAssertTrue(second.hasPrefix("\(id)-\(post)-"), "部品は ID で言う（鍵を変えても変わらない）")
  }

  // MARK: - 取る行が無い契機

  /// 取る行が 1 つも無い契機（読んだ行がどれも捨てる行）は手段を起こさず記録も残さず、読んだ位置を進めて、捨てた数を次の回の
  /// 記録に数える。
  func testATriggerWithNothingToTakeRunsNothingAndCountsTheDropsInTheNextRun() throws {
    let id = try define([
      fetch("gh", every: 1800),
      definitionNode("judge", .scheduled(.every(3600)), from: ["gh"], deliver: .taskCandidates),
    ])
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    advance(by: 1800)
    finish("judge", printed(#"{"propose":"\#(downstream("gh", "a", of: id))","title":"a に対応する"}"#))
    let sameLink =
      #"{"id":"a2","link":"https://example.com/a","body":"a の続き","#
      + #""time":"2026-10-10T09:00:00Z"}"#
    finish("gh", printed([item("a"), sameLink].joined(separator: "\n")))
    XCTAssertEqual(pending("judge", of: id), 0, "候補のあるリンクの行は、読めば捨てるので数えない")

    advance(by: 3600)
    XCTAssertEqual(calls("judge").count, 1, "取る行が無ければ手段を起こさない")
    XCTAssertEqual(store.automation(id)?.state(key: "judge").runs.count, 1, "記録も残さない")
    XCTAssertEqual(
      try store.pendingDrops(id, "judge").counts, [.proposed: 1],
      "捨てた数は持ち越す")

    finish("gh", printed([item("a"), sameLink, item("b")].joined(separator: "\n")))
    advance(by: 3600)
    XCTAssertEqual(ids("judge"), [downstream("gh", "b", of: id)])
    finish("judge", printed(""))
    XCTAssertEqual(
      store.automation(id)?.state(key: "judge").runs.first?.run?.dropped.counts, [.proposed: 1])
  }

  // MARK: - 使えなくなったストア

  /// 運転中に DB の壊れを見つけたら、ストアは使えなくなり（0 件）、どの部品も予定で回らず、定義の変異を断る。
  func testABrokenDatabaseFoundWhileRunningStopsEveryNodeAndRefusesChanges() throws {
    _ = try define([
      fetch("gh", every: 1800),
      definitionNode("digest", .arrival, from: ["gh"], deliver: .report),
    ])

    func breaks(_: AutomationDatabase, _: inout AutomationMemory) throws {
      throw SQLiteError(code: SQLITE_CORRUPT, message: "malformed")
    }

    XCTAssertThrowsError(try store.commit(sweepingAt: nil, breaks))

    XCTAssertFalse(store.available)
    XCTAssertEqual(store.automations, [])
    advance(by: 3600)
    XCTAssertEqual(calls("gh"), [], "どの部品も回らない")
    XCTAssertThrowsError(try runner.set(nil, AutomationStoreTests.definition())) {
      guard case .unavailable = $0 as? AutomationError else { return XCTFail("\($0)") }
    }
  }
}

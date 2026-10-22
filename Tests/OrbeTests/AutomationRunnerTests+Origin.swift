import XCTest

@testable import Orbe

/// 判定は出どころのある行だけを取る。処理の部品が走っている間に、それを入力にする判定の部品を足す書き換えがあると、処理の回は
/// 止まらず（何をするかは変わらない）、始めた時点では判定へ届かなかったので出どころの無い行も出しうる。判定へ届く行がどれも
/// 出どころを持たず、作った行があれば処理の回の失敗にし、そうでなければ判定が読むときに出どころの無い行を捨てて数える。
///
/// 壊れると何が起きるか: 書き換えの最中に回った処理の確定でアプリが落ちる（release では無言で終わる）。出どころの無い行が
/// 判定に渡り、候補のリンクと本文を取れない。全部が捨てられた回を成功と読み、処理が取った行を消して二度と流さない。
extension AutomationRunnerTests {
  /// 取得 `gh` → 処理 `p`（届いたら）→ 報告 `digest`（届いたら）。`p` の出力は判定へ届かない。
  private func definition(judge: Bool) -> AutomationDefinition {
    var parts = [
      fetch("gh", every: 1800),
      part("p", .arrival, from: ["gh"]),
      part("digest", .arrival, from: ["p"], deliver: .report),
    ]
    if judge {
      parts.append(part("judge", .scheduled(.every(86400)), from: ["p"], deliver: .taskCandidates))
    }
    return AutomationDefinition(name: "処理の後に判定を足す", notify: nil, parts: parts)
  }

  /// `p` が走っている間に判定の部品を足し、`p` を `stdout`（自動化の ID から組む）で終える。
  private func finishProcessAfterAddingAJudge(_ stdout: (Int) -> String) throws -> Int {
    let id = try runner.set(nil, definition(judge: false)).id
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    XCTAssertEqual(calls("p").count, 1, "前提: 届いたら処理が起きる")

    try rewrite(id, definition(judge: true))
    XCTAssertEqual(jobs.stopped, [], "前提: 処理の何をするかは変わらないので回は止まらない")
    finish("p", printed(stdout(id)))
    return id
  }

  func testAProcessRunWhoseRowsAllLackAnOriginFailsWhenAJudgeWasAddedMidRun() throws {
    let id = try finishProcessAfterAddingAJudge { _ in #"{"id":"x","note":"作った行"}"# }

    let run = try XCTUnwrap(store.automation(id)?.state(key: "p").runs.first?.run)
    XCTAssertEqual(
      try XCTUnwrap(run.failure, "処理の回の失敗にする").text(
        part: "p", ending: run.execution.ending, breach: run.breach),
      #"the rows of part "p" reach a judge part, but none has an origin (none came from a fetch part)"#)
    XCTAssertEqual(inbox("judge", of: id), 0)
    XCTAssertEqual(inbox("digest", of: id), 0, "失敗した回はどの下流にも渡さない")
    XCTAssertEqual(inbox("p", of: id), 1, "取った行は残り、次の回で取り直す")
    XCTAssertEqual(calls("p").count, 1, "失敗にした回で契機を終え、同じ行ですぐ走り直さない")
  }

  func testRowsWithoutAnOriginAreDroppedOnTheWayToAJudgeAndCounted() throws {
    let id = try finishProcessAfterAddingAJudge { id in
      [
        #"{"id":"\#(self.downstream("gh", "a", of: id))","note":"元の項目"}"#,
        #"{"id":"x","note":"作った行"}"#,
      ].joined(separator: "\n")
    }

    XCTAssertNil(store.automation(id)?.state(key: "p").runs.first?.run?.failure)
    XCTAssertEqual(inbox("judge", of: id), 1, "出どころのある行だけを判定が取る")
    XCTAssertEqual(
      ids("digest"), [downstream("gh", "a", of: id), downstream("p", "x", of: id)],
      "判定でない下流には出どころの無い行も届く（作った行は処理の ID の接頭）")
    finish("digest", printed("要約"))

    advance(by: 86400)
    finish("judge", printed(""))
    XCTAssertEqual(
      store.automation(id)?.state(key: "judge").runs.first?.run?.dropped.counts, [.unsourced: 1],
      "捨てた数は判定の次の回の記録に載る")
  }

  /// 取得 `gh` → 新しい id を作る処理 `q`（届いたら）→ 処理 `p`（毎日）→ 報告 `digest`。`judge` を足すと `p` の出力が判定へ
  /// 届く。
  private func passThroughDefinition(judge: Bool) -> AutomationDefinition {
    var parts = [
      fetch("gh", every: 1800),
      part("q", .arrival, from: ["gh"]),
      part("p", .scheduled(.every(86400)), from: ["q"]),
      part("digest", .arrival, from: ["p"], deliver: .report),
    ]
    if judge {
      parts.append(part("judge", .scheduled(.every(86400)), from: ["p"], deliver: .taskCandidates))
    }
    return AutomationDefinition(name: "出どころの無い行を素通しする", notify: nil, parts: parts)
  }

  /// 入力の行に出どころが無いだけで、その `id` を保って素通しした処理は決まりを外していない。回は成功し、印は付かず、読んだ位置は
  /// 進む（同じ行で失敗を繰り返さない）。判定は読むときに出どころなしとして捨てて数える。
  func testAProcessPassingThroughRowsWithoutAnOriginSucceedsAndTheJudgeCountsThemDropped() throws {
    let id = try runner.set(nil, passThroughDefinition(judge: false)).id
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("q", printed(#"{"id":"x","note":"作った行"}"#))
    XCTAssertEqual(inbox("p", of: id), 1, "前提: 出どころの無い行が p に溜まる")
    try rewrite(id, passThroughDefinition(judge: true))

    advance(by: 86400 - 1800)
    let x = downstream("q", "x", of: id)
    XCTAssertEqual(ids("p"), [x])
    finish("p", printed(#"{"id":"\#(x)","note":"素通し"}"#))

    let state = try XCTUnwrap(store.automation(id)?.state(key: "p"))
    XCTAssertNil(state.runs.first?.run?.failure)
    XCTAssertNil(state.runs.first?.run?.breach)
    XCTAssertNil(state.breach, "決まりに反していない部品に印を付けない")
    XCTAssertEqual(state.pending.count, 0)
    XCTAssertEqual(inbox("judge", of: id), 0)
    XCTAssertEqual(calls("p").count, 1)
    advance(by: 1800)
    XCTAssertEqual(calls("judge"), [], "取る行が無ければ判定は起きない")
    XCTAssertEqual(try store.pendingDrops(id, "judge").counts, [.unsourced: 1])
  }
}

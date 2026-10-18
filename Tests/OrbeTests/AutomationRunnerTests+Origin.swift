import XCTest

@testable import Orbe

/// 判定の部品へは出どころのある行だけが届く。処理の部品が走っている間に、それを入力にする判定の部品を足す書き換えがあると、
/// 処理の回は止まらず（何をするかは変わらない）、始めた時点では判定へ届かなかったので出どころの無い行も出しうる。その回の
/// 確定は、判定へ出どころの無い行を積まずに捨てて判定の捨てた数に数え、全部がそうなら処理の回の失敗にする。
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

  /// `p` が走っている間に判定の部品を足し、`p` を `stdout` で終える。
  private func finishProcessAfterAddingAJudge(_ stdout: String) throws -> Int {
    let id = try runner.set(nil, definition(judge: false)).id
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    XCTAssertEqual(calls("p").count, 1, "前提: 届いたら処理が起きる")

    _ = try runner.set(id, definition(judge: true))
    XCTAssertEqual(jobs.stopped, [], "前提: 処理の何をするかは変わらないので回は止まらない")
    finish("p", printed(stdout))
    return id
  }

  func testAProcessRunWhoseRowsAllLackAnOriginFailsWhenAJudgeWasAddedMidRun() throws {
    let id = try finishProcessAfterAddingAJudge(#"{"id":"x","note":"作った行"}"#)

    let run = try XCTUnwrap(store.automation(id)?.state("p").runs.first)
    XCTAssertEqual(
      run.failure,
      #"no row passed to part "judge" has an origin (it did not come from a fetch part)"#)
    XCTAssertEqual(inbox("judge", of: id), 0)
    XCTAssertEqual(inbox("digest", of: id), 0, "失敗した回はどの下流にも渡さない")
    XCTAssertEqual(inbox("p", of: id), 1, "取った行は残り、次の回で取り直す")
  }

  func testRowsWithoutAnOriginAreDroppedOnTheWayToAJudgeAndCounted() throws {
    let id = try finishProcessAfterAddingAJudge(
      [#"{"id":"gh:a","note":"元の項目"}"#, #"{"id":"x","note":"作った行"}"#].joined(
        separator: "\n"))

    XCTAssertNil(store.automation(id)?.state("p").runs.first?.failure)
    XCTAssertEqual(inbox("judge", of: id), 1, "出どころのある行だけが判定に積まれる")
    XCTAssertEqual(ids("digest"), ["gh:a", "x"], "判定でない下流には出どころの無い行も届く")
    finish("digest", printed("要約"))
    XCTAssertEqual(store.automation(id)?.state("judge").pendingDrops.counts, [.unsourced: 1])

    advance(by: 86400)
    finish("judge", printed(#"{"nothing":"候補なし"}"#))
    XCTAssertEqual(
      store.automation(id)?.state("judge").runs.first?.dropped.counts, [.unsourced: 1],
      "捨てた数は判定の次の回の記録に載る")
  }
}

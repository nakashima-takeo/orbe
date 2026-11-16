import XCTest

@testable import Orbe

/// 判定へは、処理が入力の `id` を保った行も、新しく作った行も届く。処理のノードが走っている間に、それを入力にする判定のノードを
/// 足す書き換えがあっても、処理の回は成功のまま確定し、出した行はどれも判定が読める。
///
/// 壊れると何が起きるか: 処理がまとめた行（スレッドを 1 行にしたものなど）が判定に届かず、候補にできない。書き換えの最中に
/// 回った処理の確定が失敗になり、取った行を同じ回で取り直し続ける。判定が走っている間に読んだ行が掃除され、確定の候補が指す
/// 行を失う。
extension AutomationRunnerTests {
  /// 取得 `gh` → 処理 `p`（届いたら）→ 報告 `digest`（届いたら）。`judge` を足すと `p` の出力が判定へ届く。
  private func definition(judge: Bool) -> AutomationDefinition {
    var definitionNodes = [
      fetch("gh", every: 1800),
      definitionNode("p", .arrival, from: ["gh"]),
      definitionNode("digest", .arrival, from: ["p"], deliver: .report),
    ]
    if judge {
      definitionNodes.append(
        definitionNode("judge", .scheduled(.every(86400)), from: ["p"], deliver: .taskCandidates))
    }
    return AutomationDefinition(name: "処理の後に判定を足す", notify: nil, nodes: definitionNodes)
  }

  /// 判定が走っている間、読んだ行（処理の出来事）を掃除から守る——確定の候補がその行を指すので。
  func testARunningJudgeHoldsTheRowsItRead() throws {
    let id = try define([
      definitionNode("gh", .scheduled(.every(1800)), coverage: .currentSet),
      definitionNode("p", .arrival, from: ["gh"]),
      definitionNode("judge", .scheduled(.every(86400)), from: ["p"], deliver: .taskCandidates),
    ])
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("p", printed(#"{"id":"\#(downstream("gh", "a", of: id))"}"#))

    advance(by: 86400)
    XCTAssertEqual(calls("judge").count, 1, "前提: 判定が走っている")
    XCTAssertTrue(
      store.holding().rows.contains {
        if case .event = $0 { return true }
        return false
      })
  }

  /// `p` が走っている間に判定のノードを足しても、`p` の回は成功し、入力の `id` を保った行も作った行も判定と報告へ届く。
  func testRowsAProcessMadeReachAJudgeAddedMidRun() throws {
    let id = try runner.set(nil, definition(judge: false)).id
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    XCTAssertEqual(calls("p").count, 1, "前提: 届いたら処理が起きる")
    try rewrite(id, definition(judge: true))
    XCTAssertEqual(jobs.stopped, [], "前提: 処理の何をするかは変わらないので回は止まらない")

    finish(
      "p",
      printed(
        [
          #"{"id":"\#(downstream("gh", "a", of: id))","note":"元の項目"}"#,
          #"{"id":"x","note":"作った行"}"#,
        ].joined(separator: "\n")))

    XCTAssertNil(store.automation(id)?.state(key: "p").runs.first?.run?.failure)
    XCTAssertEqual(pending("judge", of: id), 2)
    XCTAssertEqual(
      ids("digest"), [downstream("gh", "a", of: id), downstream("p", "x", of: id)],
      "作った行は処理の ID の接頭")
  }
}

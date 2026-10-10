import XCTest

@testable import Orbe

/// 取得の性質で、取得から消えた提案を Orbe が下げるかが変わる。今の集合は消えたら下げ、新着の流れは消えても下げずに判定へ
/// 見せ続け、判定が対応済みとしたときだけ下げる。
///
/// 壊れると何が起きるか: 新着だけを取る受信（自分宛の新しい DM）で、元のメッセージが次の回に取れなくなっただけで、まだ
/// 手を付けていない提案が棚から消える。全体を取る受信（担当の未完了課題）で、閉じた課題の提案が棚に残り続ける。
extension IntakeRunnerTests {
  func testCurrentSetWithdrawsAProposalWhoseLinkLeavesTheFetch() throws {
    let intake = try create(IntakeStoreTests.definition(coverage: .currentSet))
    try runner.runNow(intake.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied(#"{"propose":"a","title":"a に返信する"}"#))

    try runner.runNow(intake.id)
    jobs.finish(2, fetched(["b"]))
    jobs.finish(3, replied(""))

    XCTAssertTrue(store.proposals.isEmpty)
    XCTAssertEqual(store.intake(intake.id)?.runs.first?.withdrawn, 1)
  }

  func testNewArrivalsKeepAProposalUntilTheJudgeResolvesIt() throws {
    let intake = try create(IntakeStoreTests.definition(coverage: .newArrivals))
    try runner.runNow(intake.id)
    jobs.finish(0, fetched(["a"]))
    jobs.finish(1, replied(#"{"propose":"a","title":"a に返信する"}"#))

    try runner.runNow(intake.id)
    jobs.finish(2, fetched(["b"]))
    XCTAssertTrue(
      prompt(3).contains(#"{"link":"https://example.com/a","title":"a に返信する"}"#),
      "取得から消えた提案も判定に見せる")
    jobs.finish(3, replied(""))

    XCTAssertEqual(store.proposals.map(\.state), [.open], "取得から消えても下げない")
    XCTAssertEqual(store.shelf(of: store.proposals[0])?.id, intake.id, "棚に出し続ける")
    XCTAssertEqual(store.intake(intake.id)?.runs.first?.withdrawn, 0)

    try runner.runNow(intake.id)
    jobs.finish(4, fetched(["c"]))
    jobs.finish(5, replied(#"{"resolve":"https://example.com/a"}"#))

    XCTAssertTrue(store.proposals.isEmpty, "判定が対応済みとしたら下げる")
    XCTAssertEqual(store.intake(intake.id)?.runs.first?.judge?.resolved, 1)
  }
}

import OrbeTestSupport
import XCTest

@testable import Orbe

/// gh の 1 回の呼び出しを時間上限で打ち切った後、出力を継いだ孫が pipe を握っていても、猶予で返ること。
///
/// 壊れると、ネット待ちで止まった gh を打ち切ったのに、gh が背景に残した子プロセス（資格情報の helper など）が生きている限り、呼び出しが
/// 返らない。その呼び出しを待つ一覧の取得や、PR の状態の読みが、止まったままになる。
final class GitHubCLITimeoutTests: OrbeTestCase {
  func testATimedOutCallReturnsWhileAGrandchildHoldsThePipes() throws {
    // 返らない実行体と、セッションを離れた孫を作る足場（git の hook と同じ sh を、gh として起こす）。
    let fixture = try GitHangFixture()
    let gh = try fixture.installScript("gh", body: fixture.pipeHoldingBody)
    let clock = ManualClock()
    let cli = GitHubCLI(clock: clock.waits)
    var output: GitHubCLI.Output?
    DispatchQueue.global().async {
      let out = cli.runSync(gh, [], cwd: fixture.dir.path)
      DispatchQueue.main.async { output = out }
    }
    XCTAssertTrue(fixture.waitUntilHung(), "前提: 孫が pipe を握ったまま、gh が止まっている")

    let limit = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline != nil })?.deadline, "時間上限の期限で眠る")
    clock.advance(to: limit)
    let grace = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline != nil })?.deadline,
      "打ち切った後、読み終わりを猶予の期限まで待つ（期限なしでは待たない）")
    clock.advance(to: grace)
    pumpMain(until: { output != nil }, "猶予で返る")

    XCTAssertEqual(output?.failure, .timedOut)
    XCTAssertTrue(
      fixture.grandchildIsAlive(), "前提: 孫が pipe を握っていて、読み終わりは来ていない（猶予で返った）")
  }
}

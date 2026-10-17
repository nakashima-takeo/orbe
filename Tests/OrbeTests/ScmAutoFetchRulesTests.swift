import XCTest

@testable import Orbe

/// 裏の fetch をいつ撃つか（時刻を引数で渡す）: 前回の fetch・pull の終わりから 180 秒、撃たない条件、認証の失敗での止まりと
/// 手の操作での解除、時刻の進め方、人の操作に譲ること。
///
/// 壊れると何が起きるか。パネルを閉じても背後に回っても fetch し続け、毎回承認を求める ssh-agent が 3 分ごとに割り込む・
/// 認証に落ちる remote へ撃ち続ける・失敗のたびにすぐ撃ち直す・人の pull と裏の fetch が並んで後の側が落ちる。
final class ScmAutoFetchRulesTests: OrbeTestCase {
  private let start = Date(timeIntervalSinceReferenceDate: 0)
  private let interval = ScmAutoFetchRules.interval

  /// 欲しがる面があり前面の、まだ一度も fetch していない係。
  private func wanted() -> ScmAutoFetchRules {
    var rules = ScmAutoFetchRules(isAppActive: true)
    rules.isWanted = true
    return rules
  }

  private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  /// まだ fetch していなければすぐ撃ち、撃った後は前回の終わりから 180 秒で撃つ（過ぎていればすぐ）。
  func testItFiresAnIntervalAfterTheLastFetchEnded() {
    var rules = wanted()
    XCTAssertEqual(rules.delay(at: start), 0)
    rules.backgroundDidStart()
    rules.backgroundDidFinish(nil, at: start)
    XCTAssertEqual(rules.delay(at: at(60)), interval - 60)
    XCTAssertEqual(rules.delay(at: at(interval + 30)), 0, "過ぎていればすぐ")
  }

  /// 欲しがる面が無い・Orbe が背後・裏の fetch が走っている・人のネット操作がある間は撃たない。
  func testItDoesNotFireWhileUnwantedInTheBackgroundOrBusy() {
    var rules = wanted()
    rules.isWanted = false
    XCTAssertNil(rules.delay(at: start), "欲しがる面が無い")
    rules = wanted()
    rules.isAppActive = false
    XCTAssertNil(rules.delay(at: start), "Orbe が背後")
    rules = wanted()
    rules.backgroundDidStart()
    XCTAssertNil(rules.delay(at: start), "裏の fetch が走っている")
    rules = wanted()
    rules.humanWillStart()
    XCTAssertNil(rules.delay(at: start), "人のネット操作がある")
    rules.humanDidFinish(.push, .cancelled, at: start)
    XCTAssertEqual(rules.delay(at: start), 0, "人の操作が終われば撃てる")
  }

  /// 裏の fetch が通っても落ちても次は 180 秒後（落ちたら黙って次の周期を待つ）。止めた（人に譲った）なら前回の時刻のまま。
  func testAFailedBackgroundFetchWaitsForTheNextPeriodAndAStoppedOneKeepsTheTime() {
    var rules = wanted()
    rules.backgroundDidStart()
    rules.backgroundDidFinish(.reason("timed out"), at: start)
    XCTAssertEqual(rules.delay(at: start), interval, "落ちた終わりから数える")

    rules.backgroundDidStart()
    rules.backgroundDidFinish(.cancelled, at: at(100))
    XCTAssertEqual(rules.delay(at: at(100)), interval - 100, "止めた時刻からは数えない")
  }

  /// 認証・ホスト鍵の失敗の後は撃たない。手の push の類が通れば解け（時刻は進めない）、手の fetch・pull・同期が通れば解けて
  /// そこから数える。手の操作が落ちたなら解けない。
  func testAnAuthenticationFailureStopsItUntilAManualNetworkOperationSucceeds() {
    for failure in [GitWriteFailure.authentication, .unknownHostKey] {
      var rules = wanted()
      rules.backgroundDidStart()
      rules.backgroundDidFinish(failure, at: start)
      XCTAssertNil(rules.delay(at: at(interval * 10)), "\(failure)")

      rules.humanWillStart()
      rules.humanDidFinish(.pull, .authentication, at: at(10))
      XCTAssertNil(rules.delay(at: at(interval * 10)), "手の操作が落ちたなら止まったまま")
      rules.humanWillStart()
      rules.humanDidFinish(.push, nil, at: at(10))
      XCTAssertEqual(rules.delay(at: at(10)), 0, "push が通れば解ける（前回の時刻は無いまま）")
    }

    var rules = wanted()
    rules.backgroundDidStart()
    rules.backgroundDidFinish(.authentication, at: start)
    rules.humanWillStart()
    rules.humanDidFinish(.fetch, nil, at: at(10))
    XCTAssertEqual(rules.delay(at: at(10)), interval, "fetch が通れば解けて、そこから数える")
  }

  /// 人のネット操作の間は、裏の fetch が終わっても撃たない。
  func testItDoesNotFireUntilTheHumanOperationEndsEvenAfterTheBackgroundFetchEnds() {
    var rules = wanted()
    rules.backgroundDidStart()
    rules.humanWillStart()
    rules.backgroundDidFinish(.cancelled, at: at(1))
    XCTAssertNil(rules.delay(at: at(interval * 2)), "人の操作が終わるまで撃たない")
    rules.humanDidFinish(.fetch, nil, at: at(2))
    XCTAssertEqual(rules.delay(at: at(2)), interval)
  }
}

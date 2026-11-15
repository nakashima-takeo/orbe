import XCTest

@testable import Orbe

/// 裏の fetch をいつ撃つか（時刻を引数で渡す）: 前回の fetch・pull の段の終わりから 180 秒、撃たない条件、認証の失敗での
/// 止まりと、手のネットの段・remote 追跡 ref の値の変化での解除、時刻の進め方、人の操作に譲ること。
///
/// 壊れると何が起きるか。面が見えなくなっても背後に回っても fetch し続け、毎回承認を求める ssh-agent が 3 分ごとに割り込む・
/// 認証に落ちる remote へ撃ち続ける・失敗のたびにすぐ撃ち直す・人の pull と裏の fetch が並んで後の側が落ちる・端末で認証を
/// 直して push しても、再起動まで自動 fetch が黙って止まったまま。
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

  /// 認証の失敗で止まった係（止まった時点の remote 追跡 ref は `refs`）。
  private func blocked(refs: [String: String] = ["refs/remotes/origin/main": "a"])
    -> ScmAutoFetchRules
  {
    var rules = wanted()
    rules.backgroundDidStart()
    rules.backgroundDidFinish(.authentication, at: start)
    rules.refsAtBlockWereRead(refs, block: rules.blocks)
    return rules
  }

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
    rules.humanDidFinish()
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

  /// 認証・ホスト鍵の失敗の後は撃たない。リモートと話せたと分かる手の段（通った・競合で止まったプル・拒否された・断られた
  /// push）で解ける。話せたと分からない段（認証の失敗・止めた・その他）では解けない。
  func testAnAuthenticationFailureStopsItUntilAStepTalksToTheRemote() {
    for failure in [GitWriteFailure.authentication, .unknownHostKey] {
      var rules = wanted()
      rules.backgroundDidStart()
      rules.backgroundDidFinish(failure, at: start)
      XCTAssertNil(rules.delay(at: at(interval * 10)), "\(failure)")
    }
    let unblocking: [(SourceControl.NetworkStep, GitWriteFailure?)] = [
      (.push, nil), (.pull, nil), (.fetch, nil), (.pull, .conflicted(.merge)),
      (.push, .pushRejected), (.push, .remoteRefused("main [remote rejected] (protected)")),
    ]
    for (step, failure) in unblocking {
      var rules = blocked()
      rules.networkStepDidFinish(step, failure, at: at(10))
      XCTAssertFalse(rules.isBlocked, "\(step) \(String(describing: failure))")
    }
    let keeping: [(SourceControl.NetworkStep, GitWriteFailure?)] = [
      (.pull, .authentication), (.push, .unknownHostKey), (.fetch, .cancelled),
      (.pull, .reason("Could not resolve host: example.invalid")),
      (.push, .noPushDestination),
    ]
    for (step, failure) in keeping {
      var rules = blocked()
      rules.networkStepDidFinish(step, failure, at: at(10))
      XCTAssertTrue(rules.isBlocked, "\(step) \(String(describing: failure))")
    }
  }

  /// 前回の時刻が今になるのは、remote 追跡 ref を取り込んだ段（fetch・pull が通った・競合で止まったプル）だけ。push は
  /// 通っても時刻を進めない。
  func testOnlyAStepThatBringsTheRemoteRefsInRestartsTheInterval() {
    var rules = wanted()
    rules.networkStepDidFinish(.push, nil, at: at(10))
    XCTAssertEqual(rules.delay(at: at(10)), 0, "push は時刻を進めない")
    rules.networkStepDidFinish(.push, .remoteRefused("x"), at: at(10))
    XCTAssertEqual(rules.delay(at: at(10)), 0)
    rules.networkStepDidFinish(.fetch, nil, at: at(10))
    XCTAssertEqual(rules.delay(at: at(10)), interval)
    rules.networkStepDidFinish(.pull, .conflicted(.rebase), at: at(20))
    XCTAssertEqual(rules.delay(at: at(20)), interval, "競合で止まったプルも取り込んでいる")
  }

  /// 同期でプルが通った後に push が落ちても、プルの段で止まりが解けて時刻が進む（段ごとに受ける）。
  func testASyncWhosePullPassedUnblocksEvenIfItsPushFails() {
    var rules = blocked()
    rules.humanWillStart()
    rules.networkStepDidFinish(.pull, nil, at: at(10))
    rules.networkStepDidFinish(.push, .reason("pre-push hook failed"), at: at(11))
    rules.humanDidFinish()
    XCTAssertFalse(rules.isBlocked)
    XCTAssertEqual(rules.delay(at: at(11)), interval - 1)
  }

  /// 止まっている間に、remote 追跡 ref の値が止まった時点から変わっていれば解ける（端末・エージェントの push・fetch）。値が
  /// 同じ（何も取れなかった外の fetch・pack-refs）なら解けない。止まった時点の値を読む前、別の止まりの間に読み始めた値、
  /// 止まっていないときの値では比べない。
  func testAMoveOfTheRemoteRefsWhileStoppedUnblocks() {
    var rules = blocked(refs: ["refs/remotes/origin/main": "a"])
    XCTAssertFalse(rules.refsWereRead(["refs/remotes/origin/main": "a"], block: rules.blocks))
    XCTAssertTrue(rules.isBlocked, "値が同じなら止まったまま")
    XCTAssertTrue(rules.refsWereRead(["refs/remotes/origin/main": "b"], block: rules.blocks))
    XCTAssertFalse(rules.isBlocked)
    XCTAssertEqual(rules.delay(at: at(1)), 0, "解けたらすぐ撃てる（時刻は進めない）")

    var unread = wanted()
    unread.backgroundDidStart()
    unread.backgroundDidFinish(.authentication, at: start)
    XCTAssertFalse(unread.refsWereRead(["refs/remotes/origin/main": "b"], block: unread.blocks))
    XCTAssertTrue(unread.isBlocked, "止まった時点の値を読む前は比べない")

    var stale = blocked(refs: ["refs/remotes/origin/main": "a"])
    let earlier = stale.blocks
    stale.networkStepDidFinish(.fetch, nil, at: at(1))
    stale.backgroundDidStart()
    stale.backgroundDidFinish(.authentication, at: at(2))
    stale.refsAtBlockWereRead(["refs/remotes/origin/main": "c"], block: earlier)
    XCTAssertFalse(
      stale.refsWereRead(["refs/remotes/origin/main": "d"], block: stale.blocks),
      "前の止まりのときに読んだ値は基準にしない")
    stale.refsAtBlockWereRead(["refs/remotes/origin/main": "c"], block: stale.blocks)
    XCTAssertFalse(stale.refsWereRead(["refs/remotes/origin/main": "d"], block: earlier))
    XCTAssertTrue(stale.isBlocked, "前の止まりの間に読み始めた値では解けない")
  }

  /// 人のネット操作の間は、裏の fetch が終わっても撃たない。
  func testItDoesNotFireUntilTheHumanOperationEndsEvenAfterTheBackgroundFetchEnds() {
    var rules = wanted()
    rules.backgroundDidStart()
    rules.humanWillStart()
    rules.backgroundDidFinish(.cancelled, at: at(1))
    XCTAssertNil(rules.delay(at: at(interval * 2)), "人の操作が終わるまで撃たない")
    rules.networkStepDidFinish(.fetch, nil, at: at(2))
    rules.humanDidFinish()
    XCTAssertEqual(rules.delay(at: at(2)), interval)
  }
}

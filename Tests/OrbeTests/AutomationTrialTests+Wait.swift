import XCTest

@testable import Orbe

/// 試走の置き換え・消す・待つ。
///
/// 壊れると何が起きるか: 試し直しても前の試走の手段が走り続ける。終わりを待つ AI が時間切れまで返らない、または消した自動化の
/// 試走を待ち続ける。
extension AutomationTrialTests {
  /// 同じ自動化で始め直すと前の試走の手段が止まり、待っている読み手には新しい試走の終わりが返る。
  func testStartingAgainStopsTheRunningTrialAndWaitersGetTheNewOne() throws {
    let id = try define([fetch("gh"), part("d", from: ["gh"], deliver: .report)])
    _ = try trials.start(id, .init())
    waitCalls("gh", 1)
    var replies: [(AutomationTrial?, Bool)] = []
    trials.wait(id, timeout: .seconds(10)) { replies.append(((try? $0.get()), $1)) }

    let second = try trials.start(id, .init())
    XCTAssertEqual(jobs.stopped, [calls("gh")[0]])
    waitCalls("gh", 2)
    XCTAssertTrue(replies.isEmpty)
    finish("gh", fetched([]))
    ended(second)

    XCTAssertEqual(replies.count, 1)
    XCTAssertTrue(replies.first?.0 === second)
    XCTAssertEqual(replies.first?.1, false)
    XCTAssertTrue(try trials.trial(id) === second)
  }

  /// 時間切れは、その時点の試走を時間切れとして返す。
  func testWaitingPastTheTimeoutReturnsTheTrialSoFar() throws {
    let id = try define([fetch("gh"), part("d", from: ["gh"], deliver: .report)])
    _ = try trials.start(id, .init())
    var reply: (AutomationTrial?, Bool)?
    trials.wait(id, timeout: .milliseconds(30)) { reply = ((try? $0.get()), $1) }
    settle(until: { reply != nil })
    XCTAssertEqual(reply?.1, true)
    XCTAssertEqual(reply?.0?.running, true)
  }

  /// 自動化を消すと試走の手段が止まり、終わりを待つ読み手には時間切れを待たずに自動化が無いと返る。
  func testDeletingTheAutomationStopsItsTrialAndAnswersItsWaiters() throws {
    let id = try define([fetch("gh"), part("d", from: ["gh"], deliver: .report)])
    _ = try trials.start(id, .init())
    waitCalls("gh", 1)
    var reply: Result<AutomationTrial, AutomationError>?
    trials.wait(id, timeout: .seconds(10)) { result, _ in reply = result }
    try runner.delete(id)

    XCTAssertEqual(jobs.stopped, [calls("gh")[0]])
    guard case .failure(let error) = reply else { return XCTFail("待つ読み手に返っていない") }
    XCTAssertEqual(error, .automationNotFound(id))
  }
}

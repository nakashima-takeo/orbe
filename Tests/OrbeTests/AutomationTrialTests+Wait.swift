import XCTest

@testable import Orbe

/// 試走の ID・置き換え・押し出し・消す・待つ。
///
/// 壊れると何が起きるか: 試し直しても前の試走の手段が走り続ける。前の試走の ID で読んだ AI が、別の試走の結果を自分の試走の結果と
/// 読む。新しい定義の試走が互いに消し合う、または際限なく溜まる。終わりを待つ AI が時間切れまで返らない、または消した自動化の
/// 試走を待ち続ける。
extension AutomationTrialTests {
  /// 同じ自動化で始め直すと（保存した定義の試走を直す定義で始め直しても）前の試走の手段が止まり、前の試走の ID は知らない試走に
  /// なる。前の ID で待っている読み手にも、新しい試走ではなく知らない試走として返る。始めるときに断られた試走は、前の試走を止めない。
  func testStartingAgainStopsTheRunningTrialAndForgetsItsId() throws {
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    let first = try trials.start(.saved(id), .init())
    waitCalls("gh", 1)
    var replies: [Result<AutomationTrial, AutomationError>] = []
    trials.wait(first.id, timeout: .seconds(10)) { result, _ in replies.append(result) }

    XCTAssertThrowsError(try trials.start(.saved(id), .init(to: ["nope"])))
    XCTAssertTrue(try trials.trial(first.id) === first, "断られた試走は前の試走を置き換えない")
    XCTAssertTrue(first.running)
    XCTAssertEqual(jobs.stopped, [])
    XCTAssertTrue(replies.isEmpty)

    let current = try XCTUnwrap(store.automation(id))
    var rewrite = current.definition
    rewrite.name = "直した"
    let second = try trials.start(
      .unsaved(try store.check(.replace(id, version: current.version, rewrite))), .init())
    XCTAssertEqual(jobs.stopped, [calls("gh")[0]])
    XCTAssertNotEqual(second.id, first.id)
    guard case .failure(let error) = replies.first, replies.count == 1 else {
      return XCTFail("前の ID で待つ読み手に知らない試走が返っていない: \(replies)")
    }
    XCTAssertEqual(error, .trialNotFound(first.id))
    XCTAssertThrowsError(try trials.trial(first.id)) {
      XCTAssertEqual($0 as? AutomationError, .trialNotFound(first.id))
    }
    waitCalls("gh", 2)
    finish("gh", fetched([]))
    ended(second)
    XCTAssertTrue(try trials.trial(second.id) === second)
  }

  /// 終わりを待つ読み手には、試走の ID で指した試走の終わりが返る。
  func testWaitingReturnsTheTrialOfThatIdWhenItEnds() throws {
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    let trial = try trials.start(.saved(id), .init())
    waitCalls("gh", 1)
    var replies: [(AutomationTrial?, Bool)] = []
    trials.wait(trial.id, timeout: .seconds(10)) { replies.append(((try? $0.get()), $1)) }
    finish("gh", fetched([]))
    ended(trial)

    XCTAssertEqual(replies.count, 1)
    XCTAssertTrue(replies.first?.0 === trial)
    XCTAssertEqual(replies.first?.1, false)
  }

  /// 時間切れは、その時点の試走を時間切れとして返す。
  func testWaitingPastTheTimeoutReturnsTheTrialSoFar() throws {
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    let trial = try trials.start(.saved(id), .init())
    var reply: (AutomationTrial?, Bool)?
    trials.wait(trial.id, timeout: .milliseconds(30)) { reply = ((try? $0.get()), $1) }
    settle(until: { reply != nil })
    XCTAssertEqual(reply?.1, true)
    XCTAssertEqual(reply?.0?.running, true)
  }

  /// 自動化を消すと、その自動化の試走の手段が止まり、終わりを待つ読み手には時間切れを待たずに知らない試走と返る。新しい定義の
  /// 試走は消した自動化を持ち主にしないので続く。
  func testDeletingTheAutomationStopsItsTrialAndAnswersItsWaiters() throws {
    let id = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    let trial = try trials.start(.saved(id), .init())
    let unsaved = try trials.start(
      .unsaved(
        try store.check(
          .create(definition([fetch("new"), definitionNode("r", from: ["new"], deliver: .report)])))
      ),
      .init())
    waitCalls("gh", 1)
    waitCalls("new", 1)
    var reply: Result<AutomationTrial, AutomationError>?
    trials.wait(trial.id, timeout: .seconds(10)) { result, _ in reply = result }
    try runner.delete(id)

    XCTAssertEqual(jobs.stopped, [calls("gh")[0]])
    guard case .failure(let error) = reply else { return XCTFail("待つ読み手に返っていない") }
    XCTAssertEqual(error, .trialNotFound(trial.id))
    XCTAssertTrue(try trials.trial(unsaved.id) === unsaved)
    XCTAssertTrue(unsaved.running)
  }

  /// 新しい定義の試走は互いに置き換えず、11 個目を始めると最も古いものが止まって忘れられ、その ID で待っている読み手には知らない
  /// 試走として返る。自動化の試走は数に入らない。
  func testNewDefinitionTrialsKeepTheNewestTen() throws {
    let saved = try define([fetch("gh"), definitionNode("d", from: ["gh"], deliver: .report)])
    let savedTrial = try trials.start(.saved(saved), .init())
    let startNew = {
      try self.trials.start(
        .unsaved(
          try self.store.check(
            .create(
              self.definition([
                self.fetch("new"), self.definitionNode("r", from: ["new"], deliver: .report),
              ])))),
        .init())
    }
    let oldest = try startNew()
    waitCalls("new", 1)
    var reply: Result<AutomationTrial, AutomationError>?
    trials.wait(oldest.id, timeout: .seconds(10)) { result, _ in reply = result }
    let new = try [oldest] + (0..<AutomationTrials.newDefinitionTrials).map { _ in try startNew() }

    XCTAssertEqual(jobs.stopped, [calls("new")[0]])
    guard case .failure(let error) = reply else { return XCTFail("待つ読み手に返っていない") }
    XCTAssertEqual(error, .trialNotFound(oldest.id))
    XCTAssertThrowsError(try trials.trial(oldest.id)) {
      XCTAssertEqual($0 as? AutomationError, .trialNotFound(oldest.id))
    }
    for trial in new.dropFirst() { XCTAssertTrue(try trials.trial(trial.id) === trial) }
    XCTAssertTrue(try trials.trial(savedTrial.id) === savedTrial)
    XCTAssertEqual(Set(new.map(\.id)).count, new.count, "試走の ID は使い回さない")
  }
}

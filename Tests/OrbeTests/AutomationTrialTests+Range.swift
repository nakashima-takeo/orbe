import XCTest

@testable import Orbe

/// 試走の範囲——入口（from）と行き先（to）で指した道の上の部品だけが動き、各部品は道の上の入力だけを待つ。
///
/// 壊れると何が起きるか: 1 部品だけを試したつもりが上流の取得まで走る。合流の一部を試すと道の外の取得を待ち続けて終わらない。
/// 分岐の片方が動かない。届かない指し方が黙って何もしない試走になる。
extension AutomationTrialTests {
  /// 1 部品だけ: 溜まり（の写し）から次の本番と同じ規則で取り、上流は動かない。本番の溜まりは残る。
  func testTryingOnePartTakesItsInboxCopyAndLeavesTheUpstreamAlone() throws {
    let id = try define([fetch("gh"), part("judge", from: ["gh"], deliver: .taskCandidates)])
    try runner.flow(id, to: .part("gh"))
    finish("gh", fetched(["a"]))

    let trial = try trials.start(id, .init(from: ["judge"], to: ["judge"]))
    waitCalls("judge", 1)
    XCTAssertEqual(ids("judge"), ["gh:a"])
    XCTAssertEqual(calls("gh").count, 1, "上流は動かない")
    finish("judge", "")
    ended(trial)

    XCTAssertEqual(trial.range.path.map(\.key), ["judge"])
    XCTAssertEqual(store.automation(id)?.state("judge").inbox, 1)
  }

  /// 合流の一部: 指した 2 つの取得と判定だけが動き、判定は道の外の取得を待たない。
  func testTryingPartOfAMergeRunsOnlyThePathAndDoesNotWaitOutsideIt() throws {
    let id = try define([
      fetch("gh"), fetch("backlog"), fetch("slack"),
      part("judge", from: ["gh", "backlog", "slack"], deliver: .taskCandidates),
    ])
    let trial = try trials.start(id, .init(from: ["gh", "backlog"], to: ["judge"]))
    waitCalls("backlog", 1)
    XCTAssertEqual(calls("gh").count, 1)
    finish("gh", fetched(["a"]))
    finish("backlog", fetched(["b"]))
    waitCalls("judge", 1)
    XCTAssertEqual(Set(ids("judge")), ["gh:a", "backlog:b"])
    finish("judge", "")
    ended(trial)

    XCTAssertEqual(calls("slack"), [])
    XCTAssertEqual(trial.range.path.map(\.key), ["gh", "backlog", "judge"])
  }

  /// 分岐: 入口だけを指すと、入口から届く終わりの部品すべてへ流れる。
  func testTryingFromABranchingPartRunsEveryBranch() throws {
    let id = try define([
      fetch("gh"), part("judge", from: ["gh"], deliver: .taskCandidates),
      part("digest", from: ["gh"], deliver: .report),
    ])
    let trial = try trials.start(id, .init(from: ["gh"]))
    waitCalls("gh", 1)
    finish("gh", fetched(["a"]))
    waitCalls("judge", 1)
    waitCalls("digest", 1)
    finish("judge", "")
    finish("digest", "a が来た")
    ended(trial)

    XCTAssertEqual(trial.range.to, ["judge", "digest"])
    XCTAssertEqual(trial.passes["digest"]?.first?.run.result, .report(text: "a が来た"))
  }

  /// 指した入口から届かない行き先は断る。
  func testATargetTheEntriesDoNotReachIsRefused() throws {
    let id = try define([
      fetch("gh"), fetch("slack"), part("judge", from: ["gh"], deliver: .taskCandidates),
      part("digest", from: ["slack"], deliver: .report),
    ])
    XCTAssertThrowsError(try trials.start(id, .init(from: ["gh"], to: ["digest"]))) {
      XCTAssertEqual($0 as? AutomationError, .invalid(#"from[0] "gh" reaches no part in to"#))
    }
    XCTAssertThrowsError(try trials.start(id, .init(to: ["nope"]))) {
      XCTAssertEqual($0 as? AutomationError, .partNotFound(id, "nope"))
    }
  }
}

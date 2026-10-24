import XCTest

@testable import Orbe

/// 試走の範囲——入口（from）と行き先（to）で指した道の上の部品だけが動き、各部品は道の上の入力だけを待つ。
///
/// 壊れると何が起きるか: 1 部品だけを試したつもりが上流の取得まで走る。合流の一部を試すと道の外の取得を待ち続けて終わらない。
/// 分岐の片方が動かない。届かない指し方が黙って何もしない試走になる。
extension AutomationTrialTests {
  /// 1 部品だけ: 写しの上の読めば取る行を次の本番と同じ規則で取り、上流は動かない。本番の読めば取る行は残る。
  func testTryingOnePartTakesItsPendingRowsInTheCopyAndLeavesTheUpstreamAlone() throws {
    let id = try define([fetch("gh"), part("judge", from: ["gh"], deliver: .taskCandidates)])
    try runner.flow(id, to: .part(store.part(id, "gh")))
    finish("gh", fetched(["a"]))

    let trial = try trials.start(id, .init(from: ["judge"], to: ["judge"]))
    waitCalls("judge", 1)
    XCTAssertEqual(ids("judge"), [downstream("gh", "a", of: id)])
    XCTAssertEqual(calls("gh").count, 1, "上流は動かない")
    finish("judge", "")
    ended(trial)

    XCTAssertEqual(trial.range.path.map(\.key), ["judge"])
    XCTAssertEqual(store.automation(id)?.state(key: "judge").pending.count, 1)
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
    XCTAssertEqual(
      Set(ids("judge")), [downstream("gh", "a", of: id), downstream("backlog", "b", of: id)])
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

    XCTAssertEqual(trial.targetKeys, ["judge", "digest"])
    XCTAssertEqual(trial.passes(key: "digest").first?.run?.result, .report(text: "a が来た"))
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

  /// `limit` は取得が下流へ渡す行を先頭から絞る。絞った行は写しに無いので、受け手は読む前に消えたと数えない。
  func testALimitCutsTheRowsAFetchPassesDown() throws {
    let id = try define([
      fetch("gh"), part("p", from: ["gh"]), part("d", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(id, .init(limit: 2))
    waitCalls("gh", 1)
    finish("gh", fetched(["a", "b", "c"]))
    waitCalls("p", 1)
    XCTAssertEqual(ids("p"), [downstream("gh", "a", of: id), downstream("gh", "b", of: id)])
    finish("p", "")
    ended(trial)
    XCTAssertEqual(
      rows(trial, "gh"), [downstream("gh", "a", of: id), downstream("gh", "b", of: id)])
    XCTAssertEqual(trial.passes(key: "gh").first?.run?.result, .fetch(fresh: 3, duplicates: 0))
    XCTAssertEqual(trial.passes(key: "p").first?.run?.dropped, AutomationDrops())
  }

  /// 出来事の流れの取得でも `limit` は同じに効く: 絞った出来事を写しから消して通し番号も戻すので、「届いたら」の受け手は
  /// 絞った後の行だけを読み、絞った出来事を読む前に期限で消えたと数えない。
  func testALimitOnANewArrivalsFetchReachesAnArrivalPartAlreadyCut() throws {
    var gh = fetch("gh")
    gh.action.coverage = .newArrivals
    let id = try define([
      gh, part("p", .arrival, from: ["gh"]), part("d", from: ["p"], deliver: .report),
    ])
    let trial = try trials.start(id, .init(limit: 2))
    waitCalls("gh", 1)
    finish("gh", fetched(["a", "b", "c"]))
    waitCalls("p", 1)
    XCTAssertEqual(ids("p"), [downstream("gh", "a", of: id), downstream("gh", "b", of: id)])
    finish("p", "")
    ended(trial)
    XCTAssertEqual(
      rows(trial, "gh"), [downstream("gh", "a", of: id), downstream("gh", "b", of: id)])
    XCTAssertEqual(trial.passes(key: "p").first?.run?.dropped, AutomationDrops())
  }
}

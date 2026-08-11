import XCTest

@testable import Orbe

/// 分類器の出力が満たす**不変条件**（個別ケースではなく直積の総当たりで主張する）。
/// 語彙は 3 軸の直積なので、ケースを 1 つずつ並べる書き方では組み合わせの穴が残る——
/// 「立った事実が画面から消えていない」「安全行が損失を隠していない」の 2 つは、
/// 入力の形を総当たりして毎回確かめる。
extension DispatchWorktreeClassifierTests {

  /// **立った事実は 1 つも画面から消えない。** 12 軸の直積を回し、行が名乗った語
  /// （`vocabulary`）がすべて 右クラスタ・損失の内訳・溢れの受け皿のどれかに出ることを主張する。
  /// 受け皿の入口が「軸の先頭だけ」に狭まると、軸の中で押し出された語がここで落ちる。
  func testNoRaisedFactEverDisappears() {
    forEachShape { facts, shape in
      let r = row(facts)
      let visible = r.chips + r.lossNotes + r.overflowNotes
      for chip in r.vocabulary {
        XCTAssertTrue(
          visible.contains(chip),
          "\(chip.id) がどこにも出ない（\(shape)）")
      }
      XCTAssertTrue(
        r.overflowNotes.allSatisfy { !r.chips.contains($0) },
        "溢れの受け皿は右クラスタと重ならない（\(shape)）")
      XCTAssertTrue(
        r.lossNotes.allSatisfy { !r.overflowNotes.contains($0) },
        "損失の内訳と溢れの受け皿は重ならない（\(shape)）")
    }
  }

  /// **安全群の行が、安全の根拠を隠したまま損失の警告を出さない。**
  /// 安全行はサブラインを開かないので、溢れた語は画面に出ない——だから安全行の溢れは
  /// safe / neutral に限られていなければならず、loss の語は必ずピルに載る必要がある。
  func testSafeRowsNeverHideALossBehindTheCap() {
    forEachShape { facts, shape in
      let r = row(facts)
      guard r.group == .safe else { return }
      XCTAssertTrue(
        r.overflowNotes.allSatisfy { $0.tone != .loss },
        "安全行が loss の語を画面から落とした（\(shape)）")
      XCTAssertTrue(
        r.lossNotes.isEmpty, "安全行は失うものを持たない（\(shape)）")
      // 安全行が名乗ってよい loss の語は `PR #N open`（レビュー中の警告）だけ。それ以外が出るなら、
      // 語の意味が行の事実と食い違っている——安全行は「消えて困るものが無い」ことを通った行なので、
      // 完全喪失を主張する語（`未 push · ローカルのみ` / `remote +N`）は成り立たない。
      for chip in r.vocabulary where chip.tone == .loss {
        guard case .openPR = chip else {
          return XCTFail("安全行が損失を主張する語を名乗った: \(chip.id)（\(shape)）")
        }
      }
      let safeEvidence: [CleanChip] = r.vocabulary.filter { $0.tone == .safe }
      XCTAssertTrue(
        safeEvidence.isEmpty || safeEvidence.contains(where: { r.chips.contains($0) }),
        "安全の根拠が 1 つも右クラスタに出ていない（\(shape)）")
    }
  }

  /// 分類の入力になりうる形を総当たりする（12 軸・ピルが競合する組み合わせを網羅する）。
  private func forEachShape(_ body: (DispatchCleanFacts, String) -> Void) {
    let statuses: [GitWorktreeStatusCounts?] = [
      nil, clean, GitWorktreeStatusCounts(modified: 2, untracked: 0),
      GitWorktreeStatusCounts(modified: 2, untracked: 3),
    ]
    let operations: [GitWorktreeOperationState] = [.none, .unknown, .inProgress(.rebase)]
    for status in statuses {
      for operation in operations {
        for lockReason in [nil, "USB"] as [String?] {
          for upstream in [nil, "origin/feat/x"] as [String?] {
            for track in [nil, "[gone]", "[ahead 3]"] as [String?] {
              for unmergedCommits in [nil, 0, 4] as [Int?] {
                for openPR in [nil, 139] as [Int?] {
                  for merged in [nil, true, false] as [Bool?] {
                    let facts = DispatchCleanFacts(
                      path: "/wt/x", branch: "feat/x", lockReason: lockReason, upstream: upstream,
                      track: track,
                      closedPR: merged.map { DispatchCleanPR(number: 142, isMerged: $0) },
                      openPR: openPR, status: status, unmergedCommits: unmergedCommits,
                      operation: operation)
                    let shape = """
                      status=\(String(describing: status)) op=\(operation) \
                      lock=\(lockReason != nil) up=\(String(describing: upstream)) \
                      track=\(String(describing: track)) \
                      unmerged=\(String(describing: unmergedCommits)) \
                      openPR=\(String(describing: openPR)) \
                      closedPR=\(String(describing: merged))
                      """
                    body(facts, shape)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

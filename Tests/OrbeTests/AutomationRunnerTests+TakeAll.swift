import XCTest

@testable import Orbe

/// 毎回すべてを取る今の集合の処理——上流の今有効な項目が変わったときだけ起き、その全部を写す。
///
/// 壊れると何が起きるか: 上流が同じ結果を出し続けるたびに処理が走り直す。失敗した回の後に写し直さない。上流の項目が無くなっても
/// 前の写しが有効なまま残る。
extension AutomationRunnerTests {
  /// 取得（出力の性質は `coverage`）→ 毎回すべてを取る今の集合の処理 `copy` → 副作用 `post`。
  private func copyParts(_ coverage: AutomationCoverage = .currentSet)
    -> [AutomationDefinition.Part]
  {
    var copy = part("copy", .arrival, coverage: .currentSet)
    copy.from = [AutomationDefinition.Input(part: "gh", take: .all)]
    return [
      part("gh", .scheduled(.every(1800)), coverage: coverage), copy,
      part("post", .arrival, from: ["copy"], deliver: .sideEffect),
    ]
  }

  private func defineCopy() throws -> Int {
    try define(copyParts())
  }

  /// 毎回すべてを取る「届いたら」の部品は、上流が変わったときだけ起きる。上流が同じ結果を出し続けても起き直さない。失敗した
  /// 回の後は、上流が変わらなくても次の祖先の回でやり直す。
  func testATakeAllArrivalPartWakesOnlyWhenTheUpstreamChanges() throws {
    _ = try defineCopy()
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("copy", printed("", exit: 1))

    advance(by: 1800)
    finish("gh", fetched(["a"]))
    XCTAssertEqual(calls("copy").count, 2, "失敗した回は次の祖先の回でやり直す")
    finish("copy", printed(item("a")))

    advance(by: 1800)
    finish("gh", fetched(["a"]))
    XCTAssertEqual(calls("copy").count, 2, "上流が変わらなければ起き直さない")
  }

  /// 毎回すべてを取る「届いたら」の部品は、上流の項目の中身が変わっただけでも起き、変わった中身を写す。
  func testATakeAllArrivalPartWakesWhenAnUpstreamItemsBodyChanges() throws {
    _ = try defineCopy()
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("copy", printed(item("a")))

    advance(by: 1800)
    finish("gh", printed(item("a", body: "書き換えた本文")))

    XCTAssertEqual(calls("copy").count, 2, "版の追加で起きる")
    XCTAssertEqual(bodies("copy"), ["書き換えた本文"])
  }

  /// 再起動の後も、毎回すべてを取る「届いたら」の部品は、まだ扱い終えていない上流の変化で起きる（失敗した回の後に Orbe を
  /// 終えても、上流がまた変わるのを待たない）。扱い終えた変化では起き直さない。
  func testATakeAllArrivalPartWakesAfterARelaunchForAChangeItHasNotHandled() throws {
    _ = try defineCopy()
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("copy", printed("", exit: 1))

    launch()
    XCTAssertEqual(calls("copy").count, 2, "起動で起きる")
    finish("copy", printed(item("a")))

    launch()
    XCTAssertEqual(calls("copy").count, 2, "扱い終えた変化では起き直さない")
  }

  /// 今の集合の処理は、入力が 0 件になっても回り（空の集合を写す）、前の出力をすべて無効にする。
  func testACurrentSetProcessRunsOnAnEmptyInputAndDropsItsOutput() throws {
    let id = try defineCopy()
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("copy", printed(item("a")))
    XCTAssertEqual(store.automation(id)?.state(key: "copy").liveLinks.count, 1, "前提: 写した項目が有効")

    advance(by: 1800)
    finish("gh", printed(""))

    XCTAssertEqual(calls("copy").count, 2, "入力が 0 件でも回る")
    XCTAssertEqual(rows(try XCTUnwrap(calls("copy").last)).count, 0)
    finish("copy", printed(""))
    XCTAssertEqual(store.automation(id)?.state(key: "copy").liveLinks, [])
  }

  /// 上流の出力の性質を書き換えて今有効な項目が無効になると、毎回すべてを取る部品はすぐ起きて空の集合を写す。
  func testRewritingTheUpstreamsCoverageWakesATakeAllPart() throws {
    let id = try defineCopy()
    advance(by: 1800)
    finish("gh", fetched(["a"]))
    finish("copy", printed(item("a")))

    try rewrite(id, AutomationDefinition(name: "自動化", notify: nil, parts: copyParts(.newArrivals)))

    XCTAssertEqual(calls("copy").count, 2)
    XCTAssertEqual(rows(try XCTUnwrap(calls("copy").last)).count, 0)
  }
}

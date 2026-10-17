import XCTest

@testable import Orbe

/// 溜まりの規則——積む行・取る行・捨てる行。
///
/// 壊れると何が起きるか: 同じ項目が溜まりに二重に残り、判定が同じ項目を二度読む。出どころの無い行が判定へ届き、候補のリンクと
/// 本文が引けない。上限を書いた部品で新しい行が先に捨てられる。今の集合から消えた項目・候補のある項目が判定に渡り、提案が
/// 二重になる。ツールを持つ agent やコマンドが 100 件ごとに何度も起きて副作用が重なる、または依頼文の agent に溜まり全部が入る。
final class AutomationInboxTests: OrbeTestCase {
  typealias Parts = AutomationGraphTests

  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  /// 今の集合の取得 cs・新着の取得 na と、両方を入力にする部品 `part` を載せたグラフ。
  private func graph(_ part: AutomationPart) throws -> AutomationGraph {
    var parts = [Parts.fetch("cs"), Parts.fetch("na", .newArrivals), part]
    if part.destination == .nextPart { parts.append(Parts.agent("end", from: [part.key])) }
    return try AutomationGraph(parts)
  }

  private func node(_ part: AutomationPart) throws -> AutomationGraph.Node {
    try XCTUnwrap(graph(part).node(part.key))
  }

  private func origin(_ part: String, _ item: String, link: String? = nil)
    -> AutomationInbox.Origin
  {
    AutomationInbox.Origin(part: part, item: item, link: link ?? "https://example.com/\(item)")
  }

  private func row(
    _ seq: Int, _ id: String? = nil, from origin: AutomationInbox.Origin? = nil, size: Int = 100,
    at arrivedAt: Date? = nil
  ) -> AutomationInbox.Row {
    AutomationInbox.Row(
      seq: seq, id: id ?? "row\(seq)", origin: origin, size: size, arrivedAt: arrivedAt ?? t0)
  }

  private func arrival(_ id: String, from origin: AutomationInbox.Origin? = nil, size: Int = 100)
    -> AutomationInbox.Arrival
  {
    AutomationInbox.Arrival(id: id, origin: origin, size: size)
  }

  private func context(
    _ graph: AutomationGraph, lastOutputs: [String: Set<String>] = [:],
    proposed: Set<String> = [], now: Date? = nil
  ) -> AutomationInbox.Context {
    AutomationInbox.Context(
      graph: graph, lastOutputs: lastOutputs, proposed: { proposed.contains($0) }, now: now ?? t0)
  }

  // MARK: - 積む

  /// 同じ id の行は新しい方に置き換わり、同じ便の中でも後に届いた方が残る。
  func testArrivalsReplaceRowsWithTheSameId() throws {
    let process = try node(Parts.agent("p", from: ["cs", "na"], deliver: .nextPart))

    let push = AutomationInbox.push(
      [arrival("a"), arrival("c", size: 1), arrival("c", size: 2)], into: process,
      holding: [row(1, "a"), row(2, "b")])

    XCTAssertEqual(push.stacked, [arrival("a"), arrival("c", size: 2)])
    XCTAssertEqual(push.replaced, [1])
  }

  /// 判定の部品へは出どころのある行だけを積む。出どころの無い行は捨て、同じ id の今の行も同じ便の出どころのある行も置き換え
  /// ない。届いた行を全部捨てたら上流の回の失敗にする。
  func testAJudgeStacksOnlySourcedRows() throws {
    let judge = try node(Parts.agent("j", from: ["cs", "na"], deliver: .taskCandidates))
    let sourced = origin("na", "y")

    let push = AutomationInbox.push(
      [arrival("x"), arrival("y", from: sourced), arrival("y"), arrival("z")], into: judge,
      holding: [row(1, "x", from: origin("na", "x"))])

    XCTAssertEqual(push.stacked, [arrival("y", from: sourced)])
    XCTAssertEqual(push.unsourced, [arrival("x"), arrival("y"), arrival("z")])
    XCTAssertEqual(push.replaced, [])
    XCTAssertFalse(push.upstreamFailed)
    XCTAssertTrue(AutomationInbox.push([arrival("x")], into: judge, holding: []).upstreamFailed)
    XCTAssertFalse(AutomationInbox.push([], into: judge, holding: []).upstreamFailed, "届かない回")
  }

  /// 件数の上限は置き換えの後の溜まり全体で数え、超えた分を古い行から捨てる——今の行から、足りなければ届いた行の古い方から。
  func testMaxItemsDropsTheOldestRowsAfterReplacing() throws {
    var part = Parts.agent("p", from: ["cs", "na"], deliver: .nextPart)
    part.inboxLimit = .init(maxAgeHours: nil, maxItems: 3)
    let limited = try node(part)
    let three = [row(1, "a"), row(2, "b"), row(3, "c")]

    let overflow = AutomationInbox.push(
      [arrival("d"), arrival("e")], into: limited, holding: three)
    XCTAssertEqual(overflow.overflowed, [1, 2])
    XCTAssertEqual(overflow.stacked, [arrival("d"), arrival("e")])

    let replacing = AutomationInbox.push([arrival("a")], into: limited, holding: three)
    XCTAssertEqual(replacing.overflowed, [], "置き換えた行は数えない")

    let flood = AutomationInbox.push(
      ["p", "q", "r", "s"].map { arrival($0) }, into: limited, holding: [row(1, "a")])
    XCTAssertEqual(flood.overflowed, [1])
    XCTAssertEqual(flood.overflowedArrivals, [arrival("p")])
    XCTAssertEqual(flood.stacked, ["q", "r", "s"].map { arrival($0) })
  }

  // MARK: - 取る

  /// 今の集合の取得の部品から来た行は、その項目が前回の出力に無ければ捨てる。前回の出力が記録されていなければ全部捨てる。
  /// 新着の取得・グラフに無い部品・出どころの無い行は、集合外では捨てない。
  func testRowsWhoseItemLeftTheCurrentSetAreDropped() throws {
    let report = Parts.agent("r", from: ["cs", "na"])
    let graph = try graph(report)
    let reporter = try XCTUnwrap(graph.node("r"))
    let rows = [
      row(1, from: origin("cs", "kept")), row(2, from: origin("cs", "gone")),
      row(3, from: origin("na", "new")), row(4, from: origin("removed", "old")), row(5),
    ]

    let take = AutomationInbox.take(
      by: reporter, from: rows, in: context(graph, lastOutputs: ["cs": ["kept"]]))
    XCTAssertEqual(take.taken, [1, 3, 4, 5])
    XCTAssertEqual(take.dropped, [.init(seq: 2, reason: .leftCurrentSet)])

    let unrecorded = AutomationInbox.take(by: reporter, from: rows, in: context(graph))
    XCTAssertEqual(
      unrecorded.dropped,
      [.init(seq: 1, reason: .leftCurrentSet), .init(seq: 2, reason: .leftCurrentSet)])
  }

  /// 古さの上限を過ぎた行を捨てる。ちょうど上限の行は残す。
  func testRowsPastMaxAgeAreDropped() throws {
    var part = Parts.agent("r", from: ["cs", "na"])
    part.inboxLimit = .init(maxAgeHours: 2, maxItems: nil)
    let graph = try graph(part)
    let rows = [
      row(1, from: origin("na", "a"), at: t0 - 1), row(2, from: origin("na", "b"), at: t0),
    ]

    let take = AutomationInbox.take(
      by: try XCTUnwrap(graph.node("r")), from: rows, in: context(graph, now: t0 + 2 * 3600))

    XCTAssertEqual(take.taken, [2])
    XCTAssertEqual(take.dropped, [.init(seq: 1, reason: .expired)])
  }

  /// 判定の部品は、候補のあるリンクの行を捨て、同じリンクの行は後に届いた 1 つだけを取る。判定でない部品はどちらでも捨てない。
  func testAJudgeDropsProposedLinksAndOlderRowsOfTheSameLink() throws {
    let graph = try graph(Parts.agent("j", from: ["cs", "na"], deliver: .taskCandidates))
    let rows = [
      row(1, from: origin("na", "a", link: "L1")), row(2, from: origin("na", "b", link: "L2")),
      row(3, from: origin("na", "c", link: "L1")), row(4, from: origin("na", "d", link: "L3")),
    ]

    let take = AutomationInbox.take(
      by: try XCTUnwrap(graph.node("j")), from: rows, in: context(graph, proposed: ["L2"]))
    XCTAssertEqual(take.taken, [3, 4])
    XCTAssertEqual(
      take.dropped, [.init(seq: 1, reason: .sameLink), .init(seq: 2, reason: .proposed)])

    let reportGraph = try self.graph(Parts.agent("r", from: ["cs", "na"]))
    let reported = AutomationInbox.take(
      by: try XCTUnwrap(reportGraph.node("r")), from: rows,
      in: context(reportGraph, proposed: ["L2"]))
    XCTAssertEqual(reported.taken, [1, 2, 3, 4])
  }

  /// 行を依頼文に入れる agent だけ、古い順に件数と大きさの和の上限まで取り、先頭の 1 件だけで超えるならその 1 件を取る。ツールを
  /// 持つ agent とコマンドは全部取る。
  func testOnlyAnAgentPuttingRowsInItsPromptTakesABoundedBatch() throws {
    func taking(_ part: AutomationPart, _ sizes: [Int]) throws -> [Int] {
      let graph = try graph(part)
      let rows = sizes.enumerated().map { row($0 + 1, from: origin("na", "i\($0)"), size: $1) }
      return AutomationInbox.take(
        by: try XCTUnwrap(graph.node(part.key)), from: rows, in: context(graph)
      ).taken
    }
    let count = AutomationInbox.batchCount
    let bytes = AutomationInbox.batchBytes
    let many = Array(repeating: bytes / count, count: count + 1)
    let prompted = Parts.agent("r", from: ["cs", "na"])

    XCTAssertEqual(try taking(prompted, many), Array(1...count))
    XCTAssertEqual(try taking(prompted, [bytes / 2, bytes / 2, 1]), [1, 2])
    XCTAssertEqual(try taking(prompted, [bytes + 1, 1]), [1])
    for part in [
      Parts.agent("w", from: ["cs", "na"], tools: [Parts.tool]),
      Parts.command("s", from: ["cs", "na"]),
    ] {
      XCTAssertEqual(try taking(part, many + [bytes]), Array(1...count + 2), part.key)
    }
  }
}

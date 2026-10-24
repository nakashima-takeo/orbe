import XCTest

@testable import Orbe

/// 受け手の読み——取る行・捨てる行・読んだ位置の進め先。
///
/// 壊れると何が起きるか: 同じ下流の id の行が二重に渡る。出どころの無い行が判定へ届き、候補のリンクと本文が引けない。件数の
/// 上限で新しい行が先に捨てられる。古さで捨てた行・候補のある行が判定に渡り、提案が二重になる。前の回までに読んだ行が古く
/// なるたびに捨てた数に数え直される。行を見る agent が読めば取る行を一部しか取らない。
final class AutomationIntakeTests: OrbeTestCase {
  typealias Parts = AutomationGraphTests

  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  /// 今の集合の取得 cs（ID 1）・新着の取得 na（ID 2）と、両方を入力にする部品 `part`（ID 3）を載せたグラフの `part`。
  private func node(_ part: AutomationDefinition.Node) throws -> AutomationGraph.Node {
    var parts = [Parts.fetch("cs"), Parts.fetch("na", .newArrivals), part]
    if part.action.destination == .nextPart {
      parts.append(Parts.agent("end", from: [part.key]))
    }
    return try XCTUnwrap(AutomationGraph.numbered(parts).node(key: part.key))
  }

  private let cs = AutomationNodeID(1)
  private let na = AutomationNodeID(2)

  private func row(
    _ seq: Int, _ id: String? = nil, from edge: AutomationNodeID? = nil, link: String? = nil,
    sourced: Bool = true, at: Date? = nil, unread: Bool = true, size: Int = 10
  ) -> AutomationIntake.Row {
    let edge = edge ?? cs
    let id = id ?? "row\(seq)"
    let item = AutomationItem(
      id: id, link: link ?? "https://example.com/\(id)", body: "", time: t0)
    return AutomationIntake.Row(
      from: edge, table: edge == cs ? .item : .event, seq: seq,
      ref: edge == cs ? .version(seq) : .event(seq), source: .item(seq), id: id,
      text: String(repeating: "x", count: size), at: at ?? t0.addingTimeInterval(Double(seq)),
      origin: sourced ? AutomationIntake.Origin(part: edge, row: .version(seq), item: item) : nil,
      unread: unread)
  }

  private func ceilings(cs item: Int = 0, na event: Int = 0) -> [AutomationIntake.Ceiling] {
    [
      AutomationIntake.Ceiling(from: cs, seqs: AutomationSeqs(item: item, event: 0)),
      AutomationIntake.Ceiling(from: na, seqs: AutomationSeqs(item: 0, event: event)),
    ]
  }

  private func context(proposed: Set<String> = [], now: Date? = nil) -> AutomationIntake.Context {
    AutomationIntake.Context(
      proposed: { proposed.contains($0) }, now: now ?? t0.addingTimeInterval(3600))
  }

  /// 捨てた行（古い順に「id 理由」）。
  private func drops(_ read: AutomationIntake.Read) -> [String] {
    read.dropped.map { "\($0.row.id) \($0.reason)" }
  }

  /// 読んだ行を古い順に取り、読んだ位置はつながりと表ごとに上限の番号まで進める（その間で読まなかった番号は、読む前に無効に
  /// なった項目・版の追加や無効化の番号・期限で消えた出来事）。
  func testRowsAreTakenOldestFirstAndPositionsAdvanceToTheCeiling() throws {
    let report = try node(Parts.agent("r", from: ["cs", "na"]))

    let read = AutomationIntake.read(
      by: report, [row(5, from: na), row(3)], ceilings: ceilings(cs: 4, na: 9), in: context())

    XCTAssertEqual(read.taken.map(\.id), ["row3", "row5"])
    XCTAssertEqual(
      read.reach,
      [.init(from: cs, table: .item, seq: 4), .init(from: na, table: .event, seq: 9)])
  }

  /// 古さの上限を過ぎた行は捨てて数える。前の回までに読んだ行（毎回すべてを取る入力）は、古くなっても数え直さない。
  func testExpiredRowsAreCountedOnlyWhenNotReadBefore() throws {
    var part = Parts.agent("r", from: ["cs", "na"])
    part.from = [
      .init(part: "cs", take: .all, maxAgeHours: 1), .init(part: "na", maxAgeHours: 1),
    ]
    let report = try node(part)
    let old = t0.addingTimeInterval(-7200)

    let read = AutomationIntake.read(
      by: report,
      [
        row(1, "readOld", at: old, unread: false), row(2, "kept", unread: false),
        row(3, "newOld", from: na, at: old), row(4, "fresh", from: na),
      ], ceilings: ceilings(cs: 2, na: 4), in: context())

    XCTAssertEqual(read.taken.map(\.id), ["kept", "fresh"])
    XCTAssertEqual(drops(read), ["newOld expired"])
  }

  /// 判定だけが、出どころなし → 既に候補がある → 同じリンクの古い方 の順に捨てる。報告は捨てない。
  func testOnlyAJudgeDropsUnsourcedProposedAndOlderSameLinkRows() throws {
    let judge = try node(Parts.agent("j", from: ["cs", "na"], deliver: .taskCandidates))
    let report = try node(Parts.agent("r", from: ["cs", "na"]))
    let rows = [
      row(1, "unsourced", sourced: false), row(2, "proposed", link: "https://example.com/p"),
      row(3, "older", link: "https://example.com/same"),
      row(4, "newer", from: na, link: "https://example.com/same"),
    ]
    let proposed: Set = ["https://example.com/p"]

    let judged = AutomationIntake.read(
      by: judge, rows, ceilings: ceilings(cs: 3, na: 4), in: context(proposed: proposed))
    let reported = AutomationIntake.read(
      by: report, rows, ceilings: ceilings(cs: 3, na: 4), in: context(proposed: proposed))

    XCTAssertEqual(judged.taken.map(\.id), ["newer"])
    XCTAssertEqual(drops(judged), ["unsourced unsourced", "proposed proposed", "older sameLink"])
    XCTAssertEqual(reported.taken.count, 4)
  }

  /// 同じ下流の id の行が 2 つあれば新しい方を取る。件数の上限を超えたら、新しい方から上限まで取る。
  func testTheNewerOfTheSameIdAndTheNewestUpToTheLimitAreTaken() throws {
    var part = Parts.agent("r", from: ["cs", "na"])
    part.maxItems = 2
    let report = try node(part)

    let read = AutomationIntake.read(
      by: report,
      [row(1, "a"), row(2, "b"), row(3, "a", from: na), row(4, "c", from: na), row(5, "d")],
      ceilings: ceilings(cs: 5, na: 4), in: context())

    XCTAssertEqual(read.taken.map(\.id), ["c", "d"])
    XCTAssertEqual(drops(read), ["a replaced", "b overflow", "a overflow"], "捨てた行も古い順")
  }

  /// 行を見る agent も、読めば取る行を件数と大きさによらず 1 回で全部取る。
  func testAnAgentReadingRowsTakesEveryRowAtOnce() throws {
    let report = try node(Parts.agent("r", from: ["cs", "na"]))
    let new = (1...150).map { row($0, "new\($0)", from: na, size: 2 << 10) }

    let read = AutomationIntake.read(
      by: report, new, ceilings: ceilings(na: new.count), in: context())

    XCTAssertGreaterThan(new.map(\.text.utf8.count).reduce(0, +), 256 << 10)
    XCTAssertEqual(read.taken.count, new.count)
    XCTAssertEqual(read.reach, [.init(from: na, table: .event, seq: new.count)])
  }
}

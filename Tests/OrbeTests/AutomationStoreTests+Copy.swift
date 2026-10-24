import XCTest

@testable import Orbe

/// 写し——試走が本番の DB を区切って写す土台。
///
/// 壊れると何が起きるか: 写している間に本番が確定した行が写しに無く、試走が本番と違う行を読む。試走の変異が本番の DB に
/// 届き、試した後の本番の回で項目が新しくなくなる・候補が増える。
extension AutomationStoreTests {
  /// 1 区切りで写し切れない DB でも、区切りの間に元が書いた分まで写しに入る。写しへの変異は元に届かない。
  func testACopyTakesInWhatTheStoreWritesBetweenStepsAndKeepsItsOwnChanges() throws {
    let store = AutomationStore()
    var definition = Self.definition()
    definition.parts[1] = DesignSceneFixtures.commandPart(
      "judge", "判定", .arrival, from: ["fetch"], script: "judge", deliver: .taskCandidates)
    let id = try store.create(definition, now: Self.at).id
    let large = (0..<12).map {
      AutomationItem(
        id: "large\($0)", link: "https://example.com/large\($0)",
        body: String(repeating: "x", count: 200_000), time: Self.at)
    }
    try Self.fetch(store, id, large)

    let copy = try store.copy()
    XCTAssertNil(try copy.step(), "1 区切りでは写し切れない大きさ")
    try Self.fetch(store, id, large + [Self.item("late")])
    var copied: AutomationStore?
    while copied == nil { copied = try copy.step() }
    let twin = try XCTUnwrap(copied)

    let judge = store.part(id, "judge")
    func unread(_ store: AutomationStore) throws -> [String] {
      try XCTUnwrap(store.read(judge, of: id, baseline: nil, now: Self.at)).taken.map(\.id)
    }
    XCTAssertEqual(try unread(twin), try unread(store))
    XCTAssertEqual(try unread(twin).last, "\(store.part(id, "fetch")):late")
    XCTAssertEqual(twin.automations, store.automations)

    let before = store.automations
    _ = try twin.setPaused(id, true, now: Self.at)
    try twin.delete(id, now: Self.at)
    XCTAssertEqual(store.automations, before)
    XCTAssertEqual(try unread(store).count, 13)
  }

  /// 試走が写しに掛ける操作（行を与える・絞る）の後も、ストアのメモリは DB から開き直した値と同じ（変わった部品の状態と読めば
  /// 取る行を読み直す）。今の集合に与えた行は、既に読んだ id でも新しい項目として読める。
  func testTheTrialsOperationsKeepTheMemoryEqualToTheDatabase() throws {
    var store: AutomationStore? = AutomationStore()
    let id = try XCTUnwrap(store?.create(Self.definition(), now: Self.at).id)
    try Self.fetch(XCTUnwrap(store), id, [Self.item("a")])
    try Self.judge(XCTUnwrap(store), id)
    let fetch = try XCTUnwrap(store?.part(id, "fetch"))
    let rows = ["a", "b", "c"].map {
      AutomationNodeRow(
        id: $0,
        text: #"{"id":"\#($0)","link":"https://example.com/\#($0)","body":"\#($0)","#
          + #""time":"2026-10-10T09:00:00Z"}"#, origin: nil, source: nil)
    }
    func state(_ key: String) -> AutomationNodeState? { store?.automation(id)?.state(key: key) }

    try store?.give(rows, as: fetch, of: id, at: Self.at)
    XCTAssertEqual(
      state("fetch")?.liveLinks, Set(["a", "b", "c"].map { "https://example.com/\($0)" }))
    XCTAssertEqual(state("judge")?.pending.count, 3)
    try store?.trim(fetch, in: id, fresh: 3, keeping: 1, now: Self.at)
    XCTAssertEqual(state("fetch")?.liveLinks, ["https://example.com/a"])
    XCTAssertEqual(state("judge")?.pending.count, 1)
    let automations = store?.automations
    store = nil

    XCTAssertEqual(AutomationStore().automations, automations)
  }
}

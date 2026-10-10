import XCTest

@testable import Orbe

/// 新着の流れの受信は、自分が出して人の判断待ちの提案を、取得から消えても持ち続ける。持つ受信が居なくなった提案は忘れる。
///
/// 壊れると何が起きるか: 新着の流れの受信を消しても提案が棚の無いまま残り、画面にも AI にも行き先の無い提案が溜まる。
/// 新着の流れから今の集合へ直しても、取得に無い提案が下がらない。
extension IntakeStoreTests {
  private func streaming(_ store: IntakeStore) throws {
    _ = try store.replace(1, with: Self.definition("受信 1", coverage: .newArrivals))
  }

  func testNewArrivalsForgetAHandledProposalOnceItsLinkLeaves() throws {
    let store = try store()
    try streaming(store)
    commit(store, 1, fetched: [Self.item("a")], proposing: [Self.item("a")])
    _ = try store.accept(
      store.proposals[0].id, into: TaskStore(file: nil), workspace: nil, at: .end)

    commit(store, 1, fetched: [Self.item("b")])

    XCTAssertTrue(store.proposals.isEmpty, "人がさばいた提案は、取得から消えたら忘れる")
    XCTAssertEqual(store.intake(1)?.runs.first?.withdrawn, 0, "さばいた提案は下げた数に入れない")
  }

  func testDeletingANewArrivalsIntakeForgetsTheProposalsItHeld() throws {
    let store = try store(intakes: 2)
    try streaming(store)
    commit(store, 1, fetched: [Self.item("a")], proposing: [Self.item("a")])
    commit(store, 1, fetched: [])
    XCTAssertEqual(store.proposals.count, 1)

    try store.delete(1)

    XCTAssertTrue(store.proposals.isEmpty)
  }

  /// 取得の性質だけの書き換えは全件見直しを立てないが、誰も持たなくなった提案はその場で忘れる。
  func testSwitchingToCurrentSetForgetsTheProposalsNoLongerHeld() throws {
    let store = try store()
    try streaming(store)
    commit(store, 1, fetched: [Self.item("a")], proposing: [Self.item("a")])
    commit(store, 1, fetched: [])

    XCTAssertFalse(try store.replace(1, with: Self.definition("受信 1")).reworked)
    XCTAssertTrue(store.proposals.isEmpty)
  }
}

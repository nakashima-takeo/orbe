import Foundation
import XCTest

@testable import Orbe

/// サイドバー・新タブ画面向けドメイン操作（`displayName` の表示名解決、`reopenableClosedTabs(limit:)` の
/// 可視範囲フィルタ、`reopenClosedTab(id:now:)` の指定 ID 復元と越境拒否）を本物 SQLite で守る。
///
/// 壊れると何が起きるか。ローカルスペース見出しに現在 workspace 名が反映されない、
/// 新タブの最近閉じたタブ一覧へ他 workspace の履歴が漏れる、あるいは履歴の 2 件目以降を
/// クリックしたときに誤ったタブが復元されたり他 workspace の履歴が越境復元されたりする。
extension BrowserStoreTests {
  /// 自由スペースは自身の名を返し、ローカルスペースは現在 workspace 一致かつ非空の `currentWorkspaceName` を
  /// 優先し、空白のみ・別 workspace・永続名空ではフォールバック名へ降りる。
  func testDisplayNameResolvesFreeAndLocalWithFallback() throws {
    let t0 = Self.baseTime
    let wsA = UUID()
    let wsB = UUID()
    let store = openStore(now: t0)
    let freeSpace = try XCTUnwrap(store.freeSpaces.first)
    let localA = try XCTUnwrap(store.setCurrentWorkspace(wsA, now: t0).value)
    let localB = try XCTUnwrap(store.setCurrentWorkspace(wsB, now: t0).value)

    XCTAssertEqual(store.displayName(for: freeSpace, fallbackLocalName: "Local"), freeSpace.name)

    _ = store.setCurrentWorkspace(wsB, name: "  orbe  ", now: t0)
    XCTAssertEqual(
      store.displayName(for: localB, fallbackLocalName: "Local"), "orbe",
      "現在 workspace のローカルスペースは trim 済みの currentWorkspaceName を優先する")
    XCTAssertEqual(
      store.displayName(for: localA, fallbackLocalName: "Local"), "Local",
      "現在でない workspace のローカルスペースへ currentWorkspaceName を誤適用しない")

    _ = store.setCurrentWorkspace(wsB, name: "   ", now: t0)
    XCTAssertEqual(
      store.displayName(for: localB, fallbackLocalName: "Local"), "Local",
      "currentWorkspaceName が空白のみのときはフォールバックへ降りる")

    var namedLocal = localA
    namedLocal.name = "stored-name"
    XCTAssertEqual(
      store.displayName(for: namedLocal, fallbackLocalName: "Local"), "stored-name",
      "別 workspace でも永続名があればそれを返す")
  }

  /// `reopenableClosedTabs(limit:)` は生存自由スペースと現在 workspace ローカル由来の最新順だけを返し、
  /// `reopenClosedTab(id:now:)` は途中の指定 ID だけを元スペースへ復元して他 workspace ローカル ID は拒否する。
  func testReopenableClosedTabsFiltersScopeAndReopenByIdTargetsSpecificEntry() throws {
    let t0 = Self.baseTime
    let wsA = UUID()
    let wsB = UUID()

    let restoredId: UUID = try {
      let store = openStore(now: t0)
      let freeWork = store.freeSpaces[1]
      let localA = try XCTUnwrap(store.setCurrentWorkspace(wsA, now: t0).value)

      // 4 件を順に閉じる: free1 → localA1 → free2 → localB1（最新）。
      let free1 = try XCTUnwrap(
        store.openTab(in: freeWork.id, url: url("/free-1"), title: "F1", now: t0).value)
      XCTAssertTrue(
        store.closeTab(free1.id, recordClosed: true, now: t0.addingTimeInterval(1)).didPersist)

      let localA1 = try XCTUnwrap(
        store.openTab(in: localA.id, url: url("/local-a"), title: "LA", now: t0).value)
      XCTAssertTrue(
        store.closeTab(localA1.id, recordClosed: true, now: t0.addingTimeInterval(2)).didPersist)

      let free2 = try XCTUnwrap(
        store.openTab(in: freeWork.id, url: url("/free-2"), title: "F2", now: t0).value)
      XCTAssertTrue(
        store.closeTab(free2.id, recordClosed: true, now: t0.addingTimeInterval(3)).didPersist)

      let localB = try XCTUnwrap(store.setCurrentWorkspace(wsB, now: t0).value)
      let localB1 = try XCTUnwrap(
        store.openTab(in: localB.id, url: url("/local-b"), title: "LB", now: t0).value)
      XCTAssertTrue(
        store.closeTab(localB1.id, recordClosed: true, now: t0.addingTimeInterval(4)).didPersist)

      // wsB では localA1 を除外した最新順 [localB1, free2, free1] が返り、limit 境界も守る。
      let visibleInB = store.reopenableClosedTabs()
      XCTAssertEqual(
        visibleInB.map(\.url), [url("/local-b"), url("/free-2"), url("/free-1")],
        "他 workspace のローカル履歴を一覧から除外する")
      XCTAssertEqual(
        store.reopenableClosedTabs(limit: 2).map(\.url), [url("/local-b"), url("/free-2")])
      XCTAssertEqual(store.reopenableClosedTabs(limit: 0), [])
      XCTAssertEqual(store.reopenableClosedTabs(limit: -1), [])

      // wsA のローカル履歴 ID を wsB から直指定しても越境復元しない。
      let localAEntry = try XCTUnwrap(store.closedTabs.first { $0.url == url("/local-a") })
      XCTAssertNil(
        store.reopenClosedTab(id: localAEntry.id, now: t0.addingTimeInterval(10)).value ?? nil,
        "他 workspace ローカル履歴の ID 直指定は拒否する")
      XCTAssertNil(
        store.reopenClosedTab(id: 999_999, now: t0.addingTimeInterval(10)).value ?? nil,
        "存在しない ID は nil")

      // 最新ではない途中項目 free1 を ID 指定で復元すると、free1 だけが元スペースへ戻り他履歴は残る。
      let free1Entry = try XCTUnwrap(visibleInB.first { $0.url == url("/free-1") })
      let restored = try XCTUnwrap(
        store.reopenClosedTab(id: free1Entry.id, now: t0.addingTimeInterval(20)).value ?? nil)
      XCTAssertEqual(restored.url, url("/free-1"))
      XCTAssertEqual(restored.spaceId, freeWork.id)
      XCTAssertEqual(restored.section, .today)
      XCTAssertEqual(store.activeSpaceSelection, .free(freeWork.id))
      XCTAssertEqual(store.activeTabId(in: freeWork.id), restored.id)
      XCTAssertEqual(
        store.reopenableClosedTabs().map(\.url), [url("/local-b"), url("/free-2")],
        "指定 ID のみ履歴から除かれ他の履歴順序は保たれる")
      return restored.id
    }()

    // 1 代目の SQLite 接続解放後に再起動往復しても復元と残存履歴が永続一致する。
    let reopened = openStore(now: t0.addingTimeInterval(30))
    XCTAssertTrue(reopened.available, "再オープン時に排他ロック競合しない")
    _ = reopened.setCurrentWorkspace(wsB, now: t0.addingTimeInterval(30))
    XCTAssertEqual(reopened.reopenableClosedTabs().map(\.url), [url("/local-b"), url("/free-2")])
    XCTAssertEqual(reopened.tab(id: restoredId)?.url, url("/free-1"))
  }
}

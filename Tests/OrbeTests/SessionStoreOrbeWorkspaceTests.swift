import XCTest

@testable import Orbe

/// SessionStore が持つ「Orbe の workspace」の契約を固定する。起動時の保証が Orbe の workspace をちょうど 1 つにそろえる
/// こと、Orbe の workspace と最後の通常 workspace は消せず、Orbe の workspace はディレクトリも変えられないこと。
final class SessionStoreOrbeWorkspaceTests: OrbeTestCase {
  private let root = "/state/orbe-workspace"

  func testEnsureAppendsOrbeWorkspaceWithoutMovingActiveOrAddingTabs() {
    let a = Workspace(name: "a", rootPath: "/a")
    let b = Workspace(name: "b", rootPath: "/b")
    let store = SessionStore()
    store.load(workspaces: [a, b], activeWorkspace: 1)

    store.ensureOrbeWorkspace(rootPath: root)

    XCTAssertEqual(store.workspaces.count, 3)
    let orbe = store.workspaces[2]
    XCTAssertEqual(orbe.name, "Orbe")
    XCTAssertEqual(orbe.rootPath, root)
    XCTAssertTrue(orbe.tabs.isEmpty)
    XCTAssertEqual(store.orbeWorkspaceId, orbe.persistentId)
    XCTAssertTrue(store.current === b, "active は動かない")
  }

  /// 指している workspace があれば足さず、root だけを専用フォルダへそろえる（名前・位置は保つ）。
  func testEnsureKeepsThePointedWorkspaceAndRealignsItsRoot() {
    let orbe = Workspace(name: "secretary", rootPath: "/old/state/orbe-workspace")
    let store = SessionStore()
    store.load(
      workspaces: [orbe, Workspace(name: "a", rootPath: "/a")], activeWorkspace: 1,
      orbeWorkspaceId: orbe.persistentId)

    store.ensureOrbeWorkspace(rootPath: root)
    store.ensureOrbeWorkspace(rootPath: root)

    XCTAssertEqual(store.workspaces.map(\.name), ["secretary", "a"], "何度呼んでも増えない")
    XCTAssertEqual(orbe.rootPath, root)
    XCTAssertTrue(store.isOrbeWorkspace(0))
    XCTAssertEqual(store.originWorkspaceIndex, 1, "起源は配列で最初の通常 workspace")
  }

  /// 指す先が一覧に無ければ新しく足す。同じフォルダを root に持つ既存の workspace は通常のまま残す。
  func testEnsureAppendsWhenThePointedWorkspaceIsMissing() {
    let sameRoot = Workspace(name: "same-root", rootPath: root)
    let store = SessionStore()
    store.load(workspaces: [sameRoot], activeWorkspace: 0, orbeWorkspaceId: UUID())

    store.ensureOrbeWorkspace(rootPath: root)

    XCTAssertEqual(store.workspaces.map(\.name), ["same-root", "Orbe"])
    XCTAssertFalse(store.isOrbeWorkspace(0))
    XCTAssertTrue(store.isOrbeWorkspace(1))
  }

  func testOrbeWorkspaceCannotBeRemovedOrReRootedButCanBeRenamed() {
    let store = SessionStore()
    store.load(
      workspaces: [Workspace(name: "a", rootPath: "/a"), Workspace(name: "b", rootPath: "/b")],
      activeWorkspace: 0)
    store.ensureOrbeWorkspace(rootPath: root)

    XCTAssertEqual(store.removalBlocker(2), .orbeWorkspace)
    XCTAssertEqual(store.closeWorkspace(2, origin: .gesture), .invalid)
    XCTAssertFalse(store.canChangeDir(2))
    XCTAssertFalse(store.setWorkspaceDir(2, to: "/elsewhere"))
    XCTAssertEqual(store.workspaces[2].rootPath, root)
    XCTAssertTrue(store.renameWorkspace(2, to: "secretary"))
    XCTAssertTrue(store.canChangeDir(0))
  }

  /// 通常の workspace は 2 つ以上あれば消せ、1 つだけなら消せない（Orbe の workspace は数に入れない）。
  func testLastRegularWorkspaceCannotBeRemoved() {
    let store = SessionStore()
    store.load(
      workspaces: [Workspace(name: "a", rootPath: "/a"), Workspace(name: "b", rootPath: "/b")],
      activeWorkspace: 0)
    store.ensureOrbeWorkspace(rootPath: root)

    XCTAssertNil(store.removalBlocker(0))
    XCTAssertEqual(store.closeWorkspace(0, origin: .gesture), .activeChanged)
    XCTAssertEqual(store.workspaces.map(\.name), ["b", "Orbe"])
    XCTAssertEqual(store.removalBlocker(0), .lastRegularWorkspace)
    XCTAssertEqual(store.closeWorkspace(0, origin: .gesture), .invalid)
    XCTAssertEqual(store.originWorkspaceIndex, 0)
  }
}

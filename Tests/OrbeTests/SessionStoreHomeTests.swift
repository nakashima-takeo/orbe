import XCTest

@testable import Orbe

/// SessionStore が持つ「Home」の契約を固定する。起動時の保証が Home をちょうど 1 つにそろえる
/// こと、Home と最後の通常 workspace は消せず、Home はディレクトリも変えられないこと。Home だけが持つボードの
/// 選択と巡回。
///
/// 壊れると何が起きるか: 起動のたびに Home が増える、または既存利用者の active がずれる。
/// Home が消えたり root が専用フォルダから外れたりすると、Home のタスクの作業場と秘書が Orbe の操作の指示の無い場所で起きる。
/// 通常の workspace を全部消せると、⌘T 等で起こすタブがリポジトリに属さない Home の root で起きる。
/// ボードが巡回の環から外れると、⌘⇧] / ⌘⇧[ でボードへ戻れない・ボードから出られない。
final class SessionStoreHomeTests: OrbeTestCase {
  private let root = "/state/home"

  func testEnsureAppendsHomeWithoutMovingActiveOrAddingTabs() {
    let a = Workspace(name: "a", rootPath: "/a")
    let b = Workspace(name: "b", rootPath: "/b")
    let store = SessionStore()
    store.load(workspaces: [a, b], activeWorkspace: 1)

    store.ensureHome(rootPath: root)

    XCTAssertEqual(store.workspaces.count, 3)
    let home = store.workspaces[2]
    XCTAssertEqual(home.name, "Home")
    XCTAssertEqual(home.rootPath, root)
    XCTAssertTrue(home.tabs.isEmpty)
    XCTAssertEqual(home.selection, .board, "足した Home はボードを選んでいる")
    XCTAssertEqual(store.homeWorkspaceId, home.persistentId)
    XCTAssertTrue(store.current === b, "active は動かない")
  }

  /// 指している workspace があれば足さず、root だけを専用フォルダへそろえる（名前・位置は保つ）。
  func testEnsureKeepsThePointedWorkspaceAndRealignsItsRoot() {
    let home = Workspace(name: "secretary", rootPath: "/old/state/home")
    let store = SessionStore()
    store.load(
      workspaces: [home, Workspace(name: "a", rootPath: "/a")], activeWorkspace: 1,
      homeWorkspaceId: home.persistentId)

    store.ensureHome(rootPath: root)
    store.ensureHome(rootPath: root)

    XCTAssertEqual(store.workspaces.map(\.name), ["secretary", "a"], "何度呼んでも増えない")
    XCTAssertEqual(home.rootPath, root)
    XCTAssertEqual(home.selection, .board, "タブ 0 で読み込んだ Home は空でなくボードを選ぶ")
    XCTAssertTrue(store.isHome(0))
    XCTAssertEqual(store.originWorkspaceIndex, 1, "起源は配列で最初の通常 workspace")
  }

  /// 指す先が一覧に無ければ新しく足す。同じフォルダを root に持つ既存の workspace は通常のまま残す。
  func testEnsureAppendsWhenThePointedWorkspaceIsMissing() {
    let sameRoot = Workspace(name: "same-root", rootPath: root)
    let store = SessionStore()
    store.load(workspaces: [sameRoot], activeWorkspace: 0, homeWorkspaceId: UUID())

    store.ensureHome(rootPath: root)

    XCTAssertEqual(store.workspaces.map(\.name), ["same-root", "Home"])
    XCTAssertFalse(store.isHome(0))
    XCTAssertTrue(store.isHome(1))
  }

  func testHomeCannotBeRemovedOrReRootedButCanBeRenamed() {
    let store = SessionStore()
    store.load(
      workspaces: [Workspace(name: "a", rootPath: "/a"), Workspace(name: "b", rootPath: "/b")],
      activeWorkspace: 0)
    store.ensureHome(rootPath: root)

    XCTAssertEqual(store.removalBlocker(2), .home)
    XCTAssertEqual(store.closeWorkspace(2, origin: .gesture), .invalid)
    XCTAssertFalse(store.canChangeDir(2))
    XCTAssertFalse(store.setWorkspaceDir(2, to: "/elsewhere"))
    XCTAssertEqual(store.workspaces[2].rootPath, root)
    XCTAssertTrue(store.renameWorkspace(2, to: "secretary"))
    XCTAssertTrue(store.canChangeDir(0))
  }

  /// 通常の workspace は 2 つ以上あれば消せ、1 つだけなら消せない（Home は数に入れない）。
  func testLastRegularWorkspaceCannotBeRemoved() {
    let store = SessionStore()
    store.load(
      workspaces: [Workspace(name: "a", rootPath: "/a"), Workspace(name: "b", rootPath: "/b")],
      activeWorkspace: 0)
    store.ensureHome(rootPath: root)

    XCTAssertNil(store.removalBlocker(0))
    XCTAssertEqual(store.closeWorkspace(0, origin: .gesture), .activeChanged)
    XCTAssertEqual(store.workspaces.map(\.name), ["b", "Home"])
    XCTAssertEqual(store.removalBlocker(0), .lastRegularWorkspace)
    XCTAssertEqual(store.closeWorkspace(0, origin: .gesture), .invalid)
    XCTAssertEqual(store.workspaces.map(\.name), ["b", "Home"], "消せないときは一覧を変えない")
    XCTAssertEqual(store.originWorkspaceIndex, 0)
  }

  // MARK: - ボードの巡回

  /// ⌘⇧] / ⌘⇧[ は「ボード → タブ 1 … タブ n → ボード」を 1 つの環として回る。
  func testCycleRunsThroughTheBoardAndEveryTabAsOneRing() {
    let store = SessionStore()
    store.load(workspaces: [Workspace(name: "a", rootPath: "/a")], activeWorkspace: 0)
    store.ensureHome(rootPath: root)
    store.setActiveWorkspace(1)
    let (first, second) = (TerminalTab(cwd: "/tmp"), TerminalTab(cwd: "/tmp"))
    _ = store.insertTabUnselected(first, intoWorkspaceAt: 1)
    _ = store.insertTabUnselected(second, intoWorkspaceAt: 1)
    XCTAssertEqual(store.current.selection, .board, "前提: ボードを選んでいる")

    var forward: [Workspace.Selection] = []
    for _ in 0..<3 {
      store.nextSelection().map { store.recordSelection($0) }
      forward.append(store.current.selection)
    }
    XCTAssertEqual(forward, [.tab(first), .tab(second), .board])
    XCTAssertEqual(store.prevSelection(), .tab(second), "ボードの前は末尾のタブ")
  }

  /// タブが 0 枚の Home では、巡回してもボードのまま。
  func testCycleWithoutTabsStaysOnTheBoard() {
    let store = SessionStore()
    store.load(workspaces: [Workspace(name: "a", rootPath: "/a")], activeWorkspace: 0)
    store.ensureHome(rootPath: root)
    store.setActiveWorkspace(1)

    XCTAssertEqual(store.nextSelection(), .board)
    XCTAssertEqual(store.prevSelection(), .board)
  }
}

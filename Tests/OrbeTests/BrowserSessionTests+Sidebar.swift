import Foundation
import XCTest

@testable import Orbe

/// `BrowserSession` の workspace 名同期ゲートと、サイドバー右クリックメニュー（`BrowserContextMenu`）の
/// 項目出し分けおよび実セッションに対する実行ディスパッチを守る。
///
/// 壊れると何が起きるか。起動前同期で `currentWorkspaceName` が汚染される・改名や WS 切替で
/// ローカルスペース名が追従しない、ローカルスペースに禁止されている `Favorites` 昇格メニューが出る、
/// あるいは右クリックメニューからの区分移動・閉鎖がセッション状態へ反映されない。
extension BrowserSessionTests {
  /// `start` 前の `syncCurrentWorkspace` は名前も ID も書き換えず、開始後は同一 WS の改名同期と
  /// 別 WS 切替同期の両方を反映する。
  func testWorkspaceNameSyncFollowsStartGateRenameAndSwitch() {
    let wsA = UUID()
    let wsB = UUID()
    let store = BrowserStore.inMemory(language: .ja, now: Self.baseTime)
    let session = BrowserSession(store: store, now: { Self.baseTime })

    session.syncCurrentWorkspace(wsA, name: "early")
    XCTAssertEqual(store.currentWorkspaceName, "", "start 前の syncCurrentWorkspace は名前もゲートする")
    XCTAssertNil(store.currentWorkspaceId)

    session.start(initialWorkspaceId: wsA, workspaceName: "alpha")
    XCTAssertEqual(store.currentWorkspaceId, wsA)
    XCTAssertEqual(store.currentWorkspaceName, "alpha")

    // 同一 workspaceId の改名通知はスペースを作り直さず表示名だけを即時反映する。
    let localSpaceBefore = store.currentLocalSpace?.id
    session.syncCurrentWorkspace(wsA, name: "alpha-renamed")
    XCTAssertEqual(store.currentWorkspaceName, "alpha-renamed")
    XCTAssertEqual(store.currentLocalSpace?.id, localSpaceBefore)

    // 別 workspace へ切り替えると ID と名前を両方更新し、name 省略時は既存名を潰さない。
    session.syncCurrentWorkspace(wsB, name: "beta")
    XCTAssertEqual(store.currentWorkspaceId, wsB)
    XCTAssertEqual(store.currentWorkspaceName, "beta")

    session.syncCurrentWorkspace(wsB)
    XCTAssertEqual(store.currentWorkspaceName, "beta", "name 省略時は現在の表示名を維持する")
  }

  /// タブ右クリックメニューは自由スペースのみ `Favorites` 昇格を出しローカルスペースでは除外する。
  /// 全アクションの実行が `BrowserSession` の区分移動・閉鎖履歴へ正しく反映され、自由スペースメニューは
  /// 編集と削除の 2 入口を返す。
  func testContextMenuItemsRespectSpaceKindAndExecuteUpdatesSession() throws {
    let session = BrowserSession.inMemory(workspaceName: "orbe")
    let freeSpace = try XCTUnwrap(session.store.freeSpaces.first)
    let localSpace = try XCTUnwrap(session.store.currentLocalSpace)
    let pageURL = URL(string: "https://docs.orbe.dev/menu")!

    let freeTab = try XCTUnwrap(
      session.openTab(in: freeSpace.id, section: .today, url: pageURL, title: "Doc"))
    let localTab = try XCTUnwrap(
      session.openTab(in: localSpace.id, section: .today, url: pageURL, title: "Local"))

    // 1. 自由スペース: .today → .pinned → .favorite → .pinned → .today の全区分とメニュー出し分け。
    XCTAssertEqual(
      actions(in: BrowserContextMenu.tabItems(for: freeTab, in: .free)),
      [.pin, .favorite, .close], "自由スペースの TODAY はピン留めとお気に入り追加の両方を出す")
    BrowserContextMenu.execute(.pin, tabId: freeTab.id, on: session)
    let pinnedFree = try XCTUnwrap(session.store.tab(id: freeTab.id))
    XCTAssertEqual(pinnedFree.section, .pinned)
    XCTAssertEqual(
      actions(in: BrowserContextMenu.tabItems(for: pinnedFree, in: .free)),
      [.favorite, .unpinToToday, .close])

    BrowserContextMenu.execute(.favorite, tabId: freeTab.id, on: session)
    let favFree = try XCTUnwrap(session.store.tab(id: freeTab.id))
    XCTAssertEqual(favFree.section, .favorite)
    XCTAssertEqual(
      actions(in: BrowserContextMenu.tabItems(for: favFree, in: .free)),
      [.moveToPinned, .moveToToday, .close])

    BrowserContextMenu.execute(.moveToPinned, tabId: freeTab.id, on: session)
    XCTAssertEqual(session.store.tab(id: freeTab.id)?.section, .pinned)
    BrowserContextMenu.execute(.unpinToToday, tabId: freeTab.id, on: session)
    XCTAssertEqual(session.store.tab(id: freeTab.id)?.section, .today)
    BrowserContextMenu.execute(.favorite, tabId: freeTab.id, on: session)
    BrowserContextMenu.execute(.moveToToday, tabId: freeTab.id, on: session)
    XCTAssertEqual(session.store.tab(id: freeTab.id)?.section, .today)

    BrowserContextMenu.execute(.close, tabId: freeTab.id, on: session)
    XCTAssertNil(session.store.tab(id: freeTab.id))
    XCTAssertEqual(session.store.closedTabs.first?.url, pageURL, "メニュー閉鎖は履歴へ記録する")

    // 2. ローカルスペース: .today / .pinned いずれでも Favorites 昇格を出さない。
    XCTAssertEqual(
      actions(in: BrowserContextMenu.tabItems(for: localTab, in: .local)),
      [.pin, .close], "ローカルスペースの TODAY に Favorites 追加を出さない")
    BrowserContextMenu.execute(.pin, tabId: localTab.id, on: session)
    let pinnedLocal = try XCTUnwrap(session.store.tab(id: localTab.id))
    XCTAssertEqual(
      actions(in: BrowserContextMenu.tabItems(for: pinnedLocal, in: .local)),
      [.unpinToToday, .close], "ローカルスペースの PINNED にも Favorites 追加を出さない")

    // 3. 自由スペースメニュー: 編集・削除の 2 項目を返す。
    XCTAssertEqual(BrowserContextMenu.freeSpaceItems().map(\.action), [.edit, .delete])
  }

  private func actions(in entries: [BrowserContextMenu.TabMenuEntry])
    -> [BrowserContextMenu.TabAction]
  {
    entries.compactMap { entry in
      if case .action(let action, _) = entry { return action }
      return nil
    }
  }
}

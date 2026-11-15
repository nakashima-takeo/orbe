import XCTest

@testable import Orbe

/// サイドバーの幅・開閉・パネルとソース管理のグラフの枠の高さの記憶——app-state から起こし、下限を守り、ドラッグの終わり・
/// 開閉・パネルの切替で書き戻す。
/// レールの項目は、出しているパネルなら閉じ、別のパネルならそれへ切り替える（閉じていれば開く）。読めない・範囲外・未知の
/// 値は既定へ落とし、app-state の他の項目を巻き込まない。
///
/// 壊れると何が起きるか。再起動で幅と開閉と検索パネル・引いたグラフの枠の高さが戻らない。壊れた幅で app-state 全体が読めなくなり UI 言語まで
/// 消える。レールで検索を押してもファイルのパネルが閉じるだけ。
@MainActor
final class EditorSidebarStateTests: OrbeTestCase {
  func testCommitAndToggleWriteBackAndLoadedReadsThem() {
    let state = EditorSidebarState.loaded()
    XCTAssertEqual(state.width, 240, "記録が無ければ既定の幅")
    XCTAssertTrue(state.isOpen, "記録が無ければ開")
    state.setWidth(300)
    XCTAssertEqual(AppStatePersistence.load()?.editorSidebar, nil, "ドラッグ中は書かない")
    state.commit()
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar,
      EditorSidebarRecord(width: 300, isOpen: true, panel: "files", graphHeight: 198))
    state.select(.files)
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar,
      EditorSidebarRecord(width: 300, isOpen: false, panel: "files", graphHeight: 198))

    let reloaded = EditorSidebarState.loaded()
    XCTAssertEqual(reloaded.width, 300)
    XCTAssertFalse(reloaded.isOpen)
  }

  /// グラフの枠の高さは引いている間は書かず、離したときに書き戻して、再起動でも同じ高さ。下限（見出し＋3 行）を守り、
  /// 読めない・下限未満の記録は既定（見出し＋8 行）に倒す。
  func testTheGraphHeightKeepsTheFloorIsWrittenOnReleaseAndReloads() {
    let state = EditorSidebarState.loaded()
    XCTAssertEqual(state.graphHeight, 198, "記録が無ければ既定")
    state.setGraphHeight(40)
    XCTAssertEqual(state.graphHeight, 88, "下限")
    state.setGraphHeight(260.4)
    XCTAssertEqual(state.graphHeight, 260, "整数に丸める")
    XCTAssertNil(AppStatePersistence.load()?.editorSidebar, "引いている間は書かない")
    state.commit()
    XCTAssertEqual(EditorSidebarState.loaded().graphHeight, 260, "再起動でも同じ高さ")

    AppStatePersistence.save(AppStateFile(editorSidebar: EditorSidebarRecord(graphHeight: 30)))
    XCTAssertEqual(EditorSidebarState.loaded().graphHeight, 198, "下限未満は既定")
  }

  func testWidthKeepsTheFloorAndRounds() {
    let state = EditorSidebarState()
    state.setWidth(100)
    XCTAssertEqual(state.width, 160, "下限")
    state.setWidth(200.4)
    XCTAssertEqual(state.width, 200, "整数に丸める")
    state.setWidth(.nan)
    XCTAssertEqual(state.width, 240, "非数は既定")
  }

  func testUnreadableOrOutOfRangeRecordsFallBackWithoutLosingTheFile() throws {
    try Data(#"{"preferredLanguage":"ja","editorSidebar":"garbage"}"#.utf8).write(
      to: appStateFile())
    XCTAssertEqual(AppStatePersistence.load()?.preferredLanguage, "ja", "他の項目は生きる")
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar, EditorSidebarRecord(), "読めない記録は全 field nil")
    let garbage = EditorSidebarState.loaded()
    XCTAssertEqual(garbage.width, 240)
    XCTAssertTrue(garbage.isOpen)

    AppStatePersistence.save(
      AppStateFile(editorSidebar: EditorSidebarRecord(width: 12, isOpen: nil)))
    let narrow = EditorSidebarState.loaded()
    XCTAssertEqual(narrow.width, 240, "下限未満は既定")
    XCTAssertTrue(narrow.isOpen, "開閉の欠落は開")
  }

  func testUnpersistedStateNeverWrites() {
    let state = EditorSidebarState(width: 200, isOpen: false)
    state.commit()
    state.select(.files)
    XCTAssertNil(AppStatePersistence.load(), "配られていない既定の状態（テスト・preview）は書かない")
  }

  func testTheRailSwitchesOrClosesThePanelAndThePanelIsRemembered() {
    let state = EditorSidebarState.loaded()
    XCTAssertEqual(state.panel, .files)
    state.select(.search)
    XCTAssertEqual(state.panel, .search, "別のパネルへ切り替える")
    XCTAssertTrue(state.isOpen)
    XCTAssertEqual(EditorSidebarState.loaded().panel, .search, "再起動でも戻る")

    state.select(.search)
    XCTAssertFalse(state.isOpen, "出しているパネルを押すと閉じる")
    state.select(.files)
    XCTAssertEqual(state.panel, .files)
    XCTAssertTrue(state.isOpen, "閉じていれば開く")

    state.show(.search)
    XCTAssertEqual(state.panel, .search)
    XCTAssertTrue(state.isOpen)
    state.show(.search)
    XCTAssertTrue(state.isOpen, "出しているパネルを出しても閉じない（⌘⇧F）")
  }

  func testAnUnknownOrMissingPanelFallsBackToFiles() {
    AppStatePersistence.save(
      AppStateFile(editorSidebar: EditorSidebarRecord(width: 300, isOpen: true, panel: "bogus")))
    XCTAssertEqual(EditorSidebarState.loaded().panel, .files)
    AppStatePersistence.save(AppStateFile(editorSidebar: EditorSidebarRecord(width: 300)))
    XCTAssertEqual(EditorSidebarState.loaded().panel, .files)
  }
}

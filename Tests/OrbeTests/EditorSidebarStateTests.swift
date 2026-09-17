import XCTest

@testable import Orbe

/// サイドバーの幅と開閉の記憶——app-state から起こし、下限を守り、ドラッグの終わりと開閉で書き戻す。
/// 読めない・範囲外の値は既定へ落とし、app-state の他の項目を巻き込まない。
///
/// 壊れると何が起きるか。再起動で幅と開閉が戻らない。壊れた幅で app-state 全体が読めなくなり UI 言語まで消える。
@MainActor
final class EditorSidebarStateTests: OrbeTestCase {
  func testDefaultsWhenNothingIsStored() {
    let state = EditorSidebarState.loaded()
    XCTAssertEqual(state.width, 240)
    XCTAssertTrue(state.isOpen)
  }

  func testCommitAndToggleWriteBackAndLoadedReadsThem() {
    let state = EditorSidebarState.loaded()
    state.setWidth(300)
    XCTAssertEqual(AppStatePersistence.load()?.editorSidebar, nil, "ドラッグ中は書かない")
    state.commit()
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar, EditorSidebarRecord(width: 300, isOpen: true))
    state.toggle()
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar, EditorSidebarRecord(width: 300, isOpen: false))

    let reloaded = EditorSidebarState.loaded()
    XCTAssertEqual(reloaded.width, 300)
    XCTAssertFalse(reloaded.isOpen)
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
    state.toggle()
    XCTAssertNil(AppStatePersistence.load(), "配られていない既定の状態（テスト・preview）は書かない")
  }
}

import XCTest

@testable import Orbe

/// サイドバーの幅・開閉・パネルの記憶——app-state から起こし、下限を守り、ドラッグの終わり・開閉・パネルの切替で書き戻す。
/// レールの項目は、出しているパネルなら閉じ、別のパネルならそれへ切り替える（閉じていれば開く）。読めない・範囲外・未知の
/// 値は既定へ落とし、app-state の他の項目を巻き込まない。
///
/// 壊れると何が起きるか。再起動で幅と開閉と検索パネルが戻らない。壊れた幅で app-state 全体が読めなくなり UI 言語まで
/// 消える。レールで検索を押してもファイルのパネルが閉じるだけ。
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
      AppStatePersistence.load()?.editorSidebar,
      EditorSidebarRecord(
        width: 300, isOpen: true, panel: "files", isOutlineOpen: false, outlineFraction: 0.5))
    state.select(.files)
    XCTAssertEqual(
      AppStatePersistence.load()?.editorSidebar,
      EditorSidebarRecord(
        width: 300, isOpen: false, panel: "files", isOutlineOpen: false, outlineFraction: 0.5))

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

  /// アウトラインの開閉と区画の比も記憶する——既定は閉・半々、見出しで開閉し、境のドラッグの終わりで比を書き戻す。欠落は
  /// 閉、読めない・範囲外の比は半々へ落とす。
  func testTheOutlineOpennessAndFractionAreRemembered() throws {
    let state = EditorSidebarState.loaded()
    XCTAssertFalse(state.isOutlineOpen, "既定は閉")
    XCTAssertEqual(state.outlineFraction, 0.5)
    state.toggleOutline()
    state.setOutlineFraction(0.7)
    XCTAssertEqual(AppStatePersistence.load()?.editorSidebar?.outlineFraction, 0.5, "ドラッグ中は書かない")
    state.commit()
    let reloaded = EditorSidebarState.loaded()
    XCTAssertTrue(reloaded.isOutlineOpen)
    XCTAssertEqual(reloaded.outlineFraction, 0.7, accuracy: 0.0001)

    AppStatePersistence.save(
      AppStateFile(editorSidebar: EditorSidebarRecord(width: 240, outlineFraction: 3)))
    let odd = EditorSidebarState.loaded()
    XCTAssertFalse(odd.isOutlineOpen, "開閉の欠落は閉")
    XCTAssertEqual(odd.outlineFraction, 0.5, "範囲外の比は既定")
    try Data(#"{"editorSidebar":{"isOutlineOpen":"yes","outlineFraction":"half"}}"#.utf8).write(
      to: appStateFile())
    XCTAssertEqual(AppStatePersistence.load()?.editorSidebar, EditorSidebarRecord(), "読めない欄は nil")
  }
}

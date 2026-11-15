import XCTest

@testable import Orbe

/// diff の見せ方（インライン / 並列）の記憶——選んだ見せ方を app-state に書き、次の起動で読み戻す。読めない記録は
/// インラインに落とし、app-state の他の項目を巻き込まない。
///
/// 壊れると何が起きるか。並列を選んでも、再起動するたびにインラインへ戻る。壊れた記録 1 つで app-state 全体が読めなく
/// なり、UI 言語やサイドバーの記憶まで消える。
@MainActor
final class EditorDiffModeStateTests: OrbeTestCase {
  func testTheSelectedModeComesBackOnTheNextLaunch() {
    let state = EditorDiffModeState.loaded()
    XCTAssertEqual(state.mode, .inline, "記録が無ければインライン")
    state.select(.side)
    XCTAssertEqual(EditorDiffModeState.loaded().mode, .side)
  }

  /// 記録が読めない形でも、見せ方はインラインに落ち、app-state の他の項目は読める。
  func testAnUnreadableRecordFallsBackWithoutLosingTheFile() throws {
    try Data(#"{"preferredLanguage":"ja","editorDiffMode":5}"#.utf8).write(to: appStateFile())
    XCTAssertEqual(AppStatePersistence.load()?.preferredLanguage, "ja", "他の項目は生きる")
    XCTAssertEqual(EditorDiffModeState.loaded().mode, .inline)
  }
}

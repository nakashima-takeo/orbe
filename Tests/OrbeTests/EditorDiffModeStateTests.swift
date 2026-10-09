import XCTest

@testable import Orbe

/// diff の見せ方（インライン / 並列）の記憶——選んだ見せ方を app-state に書き、次の起動で読み戻す。
///
/// 壊れると何が起きるか。並列を選んでも、再起動するたびにインラインへ戻る。
@MainActor
final class EditorDiffModeStateTests: OrbeTestCase {
  func testTheSelectedModeComesBackOnTheNextLaunch() {
    let state = EditorDiffModeState.loaded()
    XCTAssertEqual(state.mode, .inline, "記録が無ければインライン")
    state.select(.side)
    XCTAssertEqual(EditorDiffModeState.loaded().mode, .side)
  }
}

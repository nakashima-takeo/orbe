import OrbeEditorCore
import SwiftUI
import XCTest

@testable import Orbe

/// プロジェクト検索の flow（fixture は骨の `EditorShellFixtures`。状態は本物の操作が生む）: 端末焦点から ⌘⇧F → 打鍵
/// （300ms 後に検索）→ 結果 → ⌘↓ で結果へ → ↓ → Enter（ファイルが開いて一致が選ばれ中央に。橙の地と現在の一致）→
/// レールでエクスプローラーへ切り替えると地が消える。
extension DesignFlowSnapshotTests {
  func testEditorSearch() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    let pane = scene.pane
    let tab = scene.tab
    let search = pane.projectSearch
    tab.setFaces(.terminalOnly, animated: false)
    try flow(
      "editor_search", size: NSSize(width: 1100, height: 640), render: { scene.view },
      steps: [
        ("command_shift_f", { tab.findInProject() }),
        (
          "typed",
          {
            search.setPattern("activeDocument")
            pumpMain(until: { search.phase == .done }, "打鍵から 300ms 後の検索が終わる")
          }
        ),
        ("results_focused", { search.focusResults() }),
        ("down", { search.moveSelection(by: 1) }),
        ("enter_opens", { search.activateSelection() }),
        ("explorer_hides_ground", { pane.selectPanel(.files) }),
      ])
  }
}

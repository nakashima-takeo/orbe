import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 複数カーソルの flow（fixture は gallery と同じ `EditorCodeFixtures`）。VS Code と並べて見比べる画——⌘D で同じ語を
/// 足していく（足した語の他の出現の地が ⌘D の規則で出る）・⌘⇧L で全部・全カーソルで打つ・⌥⌘↓ で下の行へ足す・
/// 全カーソルの日本語の変換・Esc で主の 1 本へ。キャレットは焦点のある面として描く。
extension DesignFlowSnapshotTests {
  func testEditorMultiCursor() throws {
    let (scene, document) = try longScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    pane.occurrences.wordDelay.schedule = { _, fire in fire() }
    let surface = try engine(document)
    let view = surface.textView
    let word = (bodyText(document) as NSString).range(of: "offset")
    func run(_ selector: String) { view.perform(NSSelectorFromString(selector), with: nil) }
    let steps: [(label: String, action: () -> Void)] = [
      (
        "caret_on_word",
        {
          surface.updateFocus(true)
          pane.occurrences.focusDidChange(surfaceFocused: true, insideFace: true)
          document.surface.selectedRange = NSRange(location: word.location + 2, length: 0)
        }
      ),
      ("cmd_d_word", { run("addSelectionToNextFindMatch:") }),  // 語を選ぶ（語の規則の続き）
      ("cmd_d_next", { run("addSelectionToNextFindMatch:") }),  // 次の同じ語を足す
      ("cmd_d_third", { run("addSelectionToNextFindMatch:") }),
      ("cmd_shift_l", { run("selectHighlights:") }),  // 全部を選ぶ（主は押した所のまま）
      (
        "typed",
        { view.insertText("value", replacementRange: NSRange(location: NSNotFound, length: 0)) }
      ),
      (
        "insert_below",
        {
          run("cancelOperation:")
          run("insertCursorBelow:")
          run("insertCursorBelow:")
        }
      ),
      (
        "composing",
        {  // 全カーソルに同じ未確定（下線）と注目位置のキャレット
          view.setMarkedText(
            "かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        }
      ),
      (
        "committed",
        { view.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0)) }
      ),
      ("escape", { run("cancelOperation:") }),  // 主の 1 本へ
    ]
    try hostedFlow("editor_multi_cursor", scene, steps: settled(pane, steps))
  }
}

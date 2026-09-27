import AppKit
import XCTest

@testable import Orbe

/// エクスプローラーの下段のアウトラインの flow（fixture は骨の gallery と同じ `EditorShellFixtures`）。見出しで開く →
/// キャレットの移動で追従 → すべて折りたたむ／すべて展開 → キーで畳む → 列で打った字から絞り込む → Esc で解く →
/// 境のドラッグ、を本物の操作で撮る。列の焦点と送りの位置を保つため、面を付けた窓の中でそのまま描く。
extension DesignFlowSnapshotTests {
  func testEditorOutline() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    let pane = scene.pane
    pane.window?.appearance = NSAppearance(named: .darkAqua)
    let outline = pane.outline
    let list = pane.outlineList.scrollView.list
    func caret(_ needle: String) {
      guard let document = pane.document else { return }
      let text = document.text.substring(NSRange(location: 0, length: document.text.length))
      document.surface.selectedRange = NSRange(
        location: (text as NSString).range(of: needle).location, length: 0)
      pumpMain(until: { outline.selectedRow != nil }, "追従")
    }
    let steps: [(label: String, action: () -> Void)] = [
      ("closed", {}),
      (
        "open",
        {
          scene.showOutline(caretAt: "func reveal(")
          pumpMain(until: { scene.isOutlineReady }, "アウトラインが揃う")
        }
      ),
      ("follow_caret", { caret("func collapseAll()") }),
      ("collapse_all", { outline.toggleCollapseAll() }),
      ("expand_all", { outline.toggleCollapseAll() }),
      (
        "collapse_class",
        {
          pane.window?.makeFirstResponder(list)
          outline.select(row: 0)
          list.keyDown(
            with: .key(String(UnicodeScalar(NSEvent.SpecialKey.leftArrow.rawValue)!), []))
        }
      ),
      (
        "filter_typed",
        {
          pane.window?.makeFirstResponder(list)
          list.keyDown(with: .key("r", []))
          pane.outlineList.field.textField.currentEditor()?.insertText("ev")
          pumpMain(until: { pane.document?.outlineFilter?.pattern == "rev" }, "絞り込みが届く")
        }
      ),
      (
        "filter_escaped",
        {
          pane.outlineList.field.textField.currentEditor()?
            .doCommand(by: #selector(NSResponder.cancelOperation(_:)))
          pumpMain(until: { pane.document?.outlineFilter == nil }, "絞り込みを解く")
        }
      ),
      ("divider_dragged", { pane.sidebar.setOutlineFraction(0.75) }),
    ]
    try snapshotInWindow(pane, name: "editor_outline", steps: steps)
  }

  /// 操作を 1 つ呼んでから、面を付けた窓の中のまま撮る、を順に繰り返す。
  private func snapshotInWindow(
    _ pane: EditorPaneView, name: String, steps: [(label: String, action: () -> Void)]
  ) throws {
    for (idx, step) in steps.enumerated() {
      step.action()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      let url = previewDir("flows").appendingPathComponent(
        String(format: "%@_%02d_%@.png", name, idx, step.label))
      try data.write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }
}

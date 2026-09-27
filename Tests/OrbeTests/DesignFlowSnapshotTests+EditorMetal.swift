import AppKit
import OrbeEditorCore
import SwiftUI
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 行の装備・俯瞰・ファイル内検索・出現の強調の flow を、新しいテキスト面（Metal）で撮る（`*_metal`）。手順は今の面の
/// flow と同じで、俯瞰の操作だけは面が自分で持つ俯瞰へ届ける。今の面の同じ名前の絵と画素で比べる（→
/// `scripts/compare-editor-engines.py`）。帯とつまみは、1 コマ描いて現れ始めさせてから現れ終わる（100ms）まで待って撮る——
/// 今の面の俯瞰はアニメーションの行き先の値を撮るので、同じ見た目にそろえる（つまみが消え始める 500ms より前）。窓に
/// 見えていない面は撮るときにだけ描くので、先に 1 コマ描かないと、撮ったコマが現れ始めのコマになる。面は 1 つの窓に
/// 載せたまま撮る——撮るたびに載せ直すと、面は窓から外れたときにポインタとドラッグの状態を捨てる（押したまま窓から外れた
/// 面には離す出来事が届かない）ので、手順をまたぐドラッグとホバーが続かない。
extension DesignFlowSnapshotTests {
  private var metal: EditorEngineChoice {
    EditorEngineChoice(metal: true, elasticScroll: true, fontSmoothing: true, language: .ja)
  }

  private func metalScene() throws -> EditorCodeFixtures.Scene {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では新しい面を作らない")
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    return try EditorCodeFixtures.scene(queriesRoot: queriesRoot, engine: metal)
  }

  private func surface(_ document: EditorDocument) throws -> MetalTextSurface {
    try XCTUnwrap(document.surface as? MetalTextSurface, "前提: 新しい面で開く")
  }

  /// 1 つの窓に載せたまま、手順ごとに撮る（名前と置き場は `flow` と同じ）。
  private func hostedFlow(
    _ name: String, _ scene: EditorCodeFixtures.Scene,
    steps: [(label: String, action: () -> Void)]
  ) throws {
    let size = NSSize(width: 1000, height: 480)
    let pane = scene.pane
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = pane
    defer { window.contentView = nil }
    let dir = previewDir("flows")
    for (index, step) in steps.enumerated() {
      step.action()
      pane.layoutSubtreeIfNeeded()
      let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      let url = dir.appendingPathComponent(
        String(format: "%@_%02d_%@.png", name, index, step.label))
      try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }

  /// 帯とつまみを現れ始めさせ、現れ終わるまで待つ。
  private func settleFades(_ pane: EditorPaneView) {
    _ = (pane.document?.surface as? MetalTextSurface)?.snapshot()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
  }

  func testEditorDecorMetal() throws {
    let scene = try metalScene()
    defer { scene.cleanup() }
    let go = try scene.tab.editor.open(scene.directory.appendingPathComponent("main.go"))
    let pane = scene.pane
    let surface = try surface(go)
    pumpMain(
      until: { scene.isReady && go.baseline != nil && go.waitUntilCaughtUp(timeout: 0) },
      "index 版が届き、裏の仕事が追いつく")
    try hostedFlow(
      "editor_decor_metal", scene,
      steps: [
        ("tabs", {}),
        (
          "scrolled_right",
          {
            surface.scroll(toX: 20 * surface.config.cell)
            self.settleFades(pane)
          }
        ),
        (
          "translucent",
          {
            pane.configure(
              translucency: ChromeTranslucency(
                effectiveOpacity: 0.6, translucent: true, blur: false),
              localization: LocalizationStore(language: .systemDefault),
              fontResolver: ChromeFontResolver(), sidebar: pane.sidebar)
          }
        ),
      ])
  }

  private func longMetalScene() throws -> (EditorCodeFixtures.Scene, EditorDocument) {
    let scene = try metalScene()
    let long = try scene.tab.editor.open(scene.directory.appendingPathComponent("Long.swift"))
    pumpMain(
      until: { scene.isReady && long.baseline != nil && long.waitUntilCaughtUp(timeout: 0) },
      "index 版が届き、裏の仕事が追いつく")
    return (scene, long)
  }

  /// 各ステップの後に、見せている文書の裏の仕事が追いつくのを待ってから撮る。
  private func caughtUpMetal(
    _ pane: EditorPaneView, _ steps: [(label: String, action: () -> Void)]
  ) -> [(label: String, action: () -> Void)] {
    steps.map { step in
      (
        step.label,
        {
          step.action()
          self.catchUp(pane)
          self.settleFades(pane)
        }
      )
    }
  }

  func testEditorOverviewMetal() throws {
    let (scene, long) = try longMetalScene()
    defer { scene.cleanup() }
    let surface = try surface(long)
    let view = surface.view
    let pointer = surface.textView.overview
    let layout = { surface.surfaceLayout }
    func sliderMid() -> NSPoint {
      let placement = surface.placementBox.read()!
      return NSPoint(
        x: layout().minimap.midX, y: placement.sliderTop + placement.sliderHeight / 2)
    }
    var grab = NSPoint.zero
    let bar = { (y: CGFloat) in NSPoint(x: layout().verticalScrollbar.minX + 7, y: y) }
    try hostedFlow(
      "editor_overview_metal", scene,
      steps: caughtUpMetal(
        scene.pane,
        [
          ("open", { _ = surface.snapshot() }),
          (
            "minimap_hover",
            { surface.inputScope { pointer.pointerMoved(to: sliderMid(), inside: true) } }
          ),
          (
            "slider_drag",
            {
              grab = sliderMid()
              view.mouseDown(with: view.mouseEvent(.leftMouseDown, at: grab))
              view.mouseDragged(with: view.mouseEvent(.leftMouseDragged, at: grab.offset(dy: 60)))
            }
          ),
          (
            "minimap_click",
            {
              view.mouseUp(with: view.mouseEvent(.leftMouseUp, at: grab.offset(dy: 60)))
              let at = NSPoint(x: layout().minimap.minX + 30, y: 30)
              view.mouseDown(with: view.mouseEvent(.leftMouseDown, at: at))
              view.mouseUp(with: view.mouseEvent(.leftMouseUp, at: at))
              surface.inputScope { pointer.pointerMoved(to: NSPoint(x: -1, y: -1), inside: false) }
            }
          ),
          (
            "scrollbar_track",
            {
              surface.inputScope { pointer.pointerMoved(to: bar(300), inside: true) }
              view.mouseDown(with: view.mouseEvent(.leftMouseDown, at: bar(300)))
            }
          ),
          (
            "scrollbar_drag",
            {
              view.mouseDragged(with: view.mouseEvent(.leftMouseDragged, at: bar(360)))
              view.mouseUp(with: view.mouseEvent(.leftMouseUp, at: bar(360)))
            }
          ),
          ("scroll_end", { long.scroll(toFirstLine: CGFloat(long.text.lineCount - 1)) }),
        ]))
  }

  func testEditorFindMetal() throws {
    let (scene, long) = try longMetalScene()
    defer { scene.cleanup() }
    _ = try surface(long)
    let pane = scene.pane
    try hostedFlow(
      "editor_find_metal", scene,
      steps: caughtUpMetal(
        pane,
        [
          ("open", {}),
          ("cmd_f", { pane.showSearch() }),
          (
            "typed",
            {
              pane.searchBar?.needle = "starts"
              pane.search.setNeedle("starts")
            }
          ),
          ("enter", { pane.search.next() }),
          ("esc", { pane.closeSearch() }),
        ]))
  }

  func testEditorOccurrencesMetal() throws {
    let (scene, long) = try longMetalScene()
    defer { scene.cleanup() }
    _ = try surface(long)
    let pane = scene.pane
    pane.occurrences.wordDelay.schedule = { _, fire in fire() }
    let text = bodyText(long) as NSString
    let word = text.range(of: "offset")
    let field = text.range(of: ": Int")
    try hostedFlow(
      "editor_occurrences_metal", scene,
      steps: caughtUpMetal(
        pane,
        [
          (
            "caret_on_word",
            {
              pane.occurrences.focusDidChange(surfaceFocused: true, insideFace: true)
              long.surface.selectedRange = NSRange(location: word.location + 2, length: 0)
            }
          ),
          ("selection", { long.surface.selectedRange = field }),
          (
            "multi_line_selection",
            {
              let rope = long.text
              let start = rope.lineStart(5) + 6
              long.surface.selectedRange = NSRange(
                location: start, length: rope.lineStart(20) + 10 - start)
            }
          ),
        ]))
  }
}

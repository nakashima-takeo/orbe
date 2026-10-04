import AppKit
import OrbeEditorCore
import SwiftUI
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// 俯瞰・ファイル内検索・出現の強調の flow（fixture は gallery と同じ `EditorCodeFixtures`）。VS Code と並べて見比べる
/// 画——ミニマップの帯のホバーとドラッグ・帯の外のクリック・スクロールバーのつまみとトラック・最終行の先までの
/// スクロール、⌘F の一致がミニマップとスクロールバーに出る様子、語の上のキャレットの出現強調と文字列の選択の出現。
///
/// 帯とつまみは、1 コマ描いて現れ始めさせてから現れ終わる（100ms）まで待って撮る（つまみが消え始める 500ms より前）。
/// 窓に見えていない面は撮るときにだけ描くので、先に 1 コマ描かないと、撮ったコマが現れ始めのコマになる。面は 1 つの窓に
/// 載せたまま撮る——撮るたびに載せ直すと、面は窓から外れたときにポインタとドラッグの状態を捨てる（押したまま窓から外れた
/// 面には離す出来事が届かない）ので、手順をまたぐドラッグとホバーが続かない。
extension DesignFlowSnapshotTests {
  func codeScene() throws -> EditorCodeFixtures.Scene {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では文書を開けない")
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    return try EditorCodeFixtures.scene(queriesRoot: queriesRoot)
  }

  /// 1 つの窓に載せたまま、手順ごとに撮る（名前と置き場は `flow` と同じ）。
  func hostedFlow(
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
  func settleFades(_ pane: EditorPaneView) {
    _ = (pane.document?.surface as? MetalTextSurface)?.snapshot()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
  }

  func longScene() throws -> (EditorCodeFixtures.Scene, EditorDocument) {
    let scene = try codeScene()
    let long = try scene.tab.editor.open(scene.directory.appendingPathComponent("Long.swift"))
    pumpMain(
      until: { scene.isReady && long.baseline != nil && long.waitUntilCaughtUp(timeout: 0) },
      "index 版が届き、裏の仕事が追いつく")
    return (scene, long)
  }

  /// 各ステップの後に、見せている文書の裏の仕事（検索・出現・色・ハンク）が追いつくのを待ち、帯とつまみが現れ終わってから
  /// 撮る。
  func settled(_ pane: EditorPaneView, _ steps: [(label: String, action: () -> Void)])
    -> [(label: String, action: () -> Void)]
  {
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

  /// ミニマップ: ホバーで帯が現れる → 帯を掴んで下へ 60pt ドラッグ（本文が追従・ドラッグ中は濃い色）→ 離して帯の外を
  /// 押す（その行が本文の中央に来る）。スクロールバー: 本体に乗るとつまみが現れ、トラックを押すとつまみの中央がそこへ
  /// 飛ぶ → 同じ押下のままドラッグ → 最終行を最上段まで送る（つまみと帯は下端、最終行の下は空き地）。
  func testEditorOverview() throws {
    let (scene, long) = try longScene()
    defer { scene.cleanup() }
    let surface = try engine(long)
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
      "editor_overview", scene,
      steps: settled(
        scene.pane,
        [
          ("open", { _ = surface.snapshot() }),  // 帯とつまみは隠れ、印（git・キャレット）は常に見える
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
              // ポインタはミニマップから出て本体の上に残る（帯は消え、つまみは見えたまま）。
              let body = NSPoint(x: layout().text.midX, y: 30)
              surface.inputScope { pointer.pointerMoved(to: body, inside: true) }
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
          ("scroll_end", { surface.scroll(toFirstLine: CGFloat(long.text.lineCount - 1)) }),
        ]))
  }

  func testEditorFind() throws {
    let (scene, _) = try longScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    try hostedFlow(
      "editor_find", scene,
      steps: settled(
        pane,
        [
          ("open", {}),
          ("cmd_f", { pane.showSearch() }),  // 本文の右上（ミニマップの左）にバー。キャレットの語が種
          (
            "typed",
            {  // needle → 全一致に地、現在の一致は不透明の地とその行の薄い地。ミニマップとスクロールバーの中央レーンにも出る
              pane.searchBar?.needle = "starts"
              pane.search.setNeedle("starts")
            }
          ),
          ("enter", { pane.search.next() }),  // 次の一致へ（現在の一致の印が動く）
          ("esc", { pane.closeSearch() }),  // 地と俯瞰の一致が消え、選択は残る
        ]))
  }

  func testEditorOccurrences() throws {
    let (scene, long) = try longScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    pane.occurrences.wordDelay.schedule = { _, fire in fire() }
    let text = bodyText(long) as NSString
    let word = text.range(of: "offset")
    let field = text.range(of: ": Int")
    try hostedFlow(
      "editor_occurrences", scene,
      steps: settled(
        pane,
        [
          (
            "caret_on_word",
            {  // 語の上のキャレット → 同じ語の出現が本文・スクロールバーの中央レーン・ミニマップに出る
              pane.occurrences.focusDidChange(surfaceFocused: true, insideFace: true)
              long.surface.selectedRange = NSRange(location: word.location + 2, length: 0)
            }
          ),
          (
            "selection",
            {  // 文字列の選択 → 他の出現に本文だけ地が付く（俯瞰には出ない）
              long.surface.selectedRange = field
            }
          ),
          (
            "multi_line_selection",
            {  // 複数行の選択 → ミニマップは途中の行を行末まで選択の色、その先は行の薄い地、終わりの行は選択の終わりまで
              let rope = long.text
              let start = rope.lineStart(5) + 6
              long.surface.selectedRange = NSRange(
                location: start, length: rope.lineStart(20) + 10 - start)
            }
          ),
        ]))
  }
}

extension NSPoint {
  fileprivate func offset(dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint {
    NSPoint(x: x + dx, y: y + dy)
  }
}

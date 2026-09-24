import AppKit
import OrbeEditorCore
import SwiftUI
import XCTest

@testable import Orbe

/// 俯瞰・ファイル内検索・出現の強調の flow（fixture は gallery と同じ `EditorCodeFixtures`）。VS Code と並べて見比べる
/// 画——ミニマップの帯のホバーとドラッグ・帯の外のクリック・スクロールバーのつまみとトラック・最終行の先までの
/// スクロール、⌘F の一致がミニマップとスクロールバーに出る様子、語の上のキャレットの出現強調と文字列の選択の出現。
extension DesignFlowSnapshotTests {
  private func longScene() throws -> (EditorCodeFixtures.Scene, EditorDocument) {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorCodeFixtures.scene(queriesRoot: queriesRoot)
    let long = try scene.tab.editor.open(scene.directory.appendingPathComponent("Long.swift"))
    pumpMain(until: { scene.isReady && long.baseline != nil }, "index 版が届く")
    return (scene, long)
  }

  func testEditorOverview() throws {
    let (scene, long) = try longScene()
    defer { scene.cleanup() }
    try flow(
      "editor_overview", size: NSSize(width: 1000, height: 480), render: { scene.view },
      steps: [("open", {})]  // 帯とつまみは隠れ、印（git・キャレット）は常に見える
        + minimapSteps(scene.pane) + scrollbarSteps(scene.pane, long))
  }

  /// ミニマップ: ホバーで帯が現れる → 帯を掴んで下へ 60pt ドラッグ（本文が追従・ドラッグ中は濃い色）→ 離して帯の外を
  /// 押す（その行が本文の中央に来る）。
  private func minimapSteps(_ pane: EditorPaneView) -> [(label: String, action: () -> Void)] {
    let minimap = pane.minimap
    func sliderMid() -> NSPoint {
      let layout = minimap.placement!
      return NSPoint(x: minimap.bounds.midX, y: layout.sliderTop + layout.sliderHeight / 2)
    }
    var grab = NSPoint.zero
    return [
      (
        "minimap_hover",
        { minimap.mouseEntered(with: minimap.mouseEvent(.mouseMoved, at: sliderMid())) }
      ),
      (
        "slider_drag",
        {
          grab = sliderMid()
          minimap.mouseDown(with: minimap.mouseEvent(.leftMouseDown, at: grab))
          minimap.mouseDragged(with: minimap.mouseEvent(.leftMouseDragged, at: grab.offset(dy: 60)))
        }
      ),
      (
        "minimap_click",
        {
          minimap.mouseUp(with: minimap.mouseEvent(.leftMouseUp, at: grab.offset(dy: 60)))
          minimap.mouseDown(with: minimap.mouseEvent(.leftMouseDown, at: NSPoint(x: 30, y: 30)))
          minimap.mouseUp(with: minimap.mouseEvent(.leftMouseUp, at: NSPoint(x: 30, y: 30)))
          minimap.mouseExited(with: minimap.mouseEvent(.mouseMoved, at: .zero))
        }
      ),
    ]
  }

  /// スクロールバー: 本体に乗るとつまみが現れ、トラックを押すとつまみの中央がそこへ飛ぶ → 同じ押下のままドラッグ →
  /// 最終行を最上段まで送る（つまみと帯は下端、最終行の下は空き地）。
  private func scrollbarSteps(_ pane: EditorPaneView, _ long: EditorDocument)
    -> [(label: String, action: () -> Void)]
  {
    let scrollbar = pane.scrollbar
    return [
      (
        "scrollbar_track",
        {
          pane.mouseEntered(with: pane.mouseEvent(.mouseMoved, at: .zero))
          scrollbar.mouseDown(with: scrollbar.mouseEvent(.leftMouseDown, at: NSPoint(x: 7, y: 300)))
        }
      ),
      (
        "scrollbar_drag",
        {
          scrollbar.mouseDragged(
            with: scrollbar.mouseEvent(.leftMouseDragged, at: NSPoint(x: 7, y: 360)))
          scrollbar.mouseUp(with: scrollbar.mouseEvent(.leftMouseUp, at: NSPoint(x: 7, y: 360)))
        }
      ),
      ("scroll_end", { long.scroll(toFirstLine: CGFloat(long.lineIndex.lineCount - 1)) }),
    ]
  }

  func testEditorFind() throws {
    let (scene, _) = try longScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    try flow(
      "editor_find", size: NSSize(width: 1000, height: 480), render: { scene.view },
      steps: [
        ("cmd_f", { pane.showSearch() }),  // 本文の右上（ミニマップの左）にバー
        (
          "typed",
          {  // needle → 全一致に地、現在の一致は不透明の地とその行の薄い地。ミニマップとスクロールバーの中央レーンにも出る
            pane.searchBar?.needle = "starts"
            pane.search.setNeedle("starts")
          }
        ),
        ("enter", { pane.search.next() }),  // 次の一致へ（現在の一致の印が動く）
        ("esc", { pane.closeSearch() }),  // 地と俯瞰の一致が消え、選択は残る
      ])
  }

  func testEditorOccurrences() throws {
    let (scene, long) = try longScene()
    defer { scene.cleanup() }
    let pane = scene.pane
    pane.occurrences.wordDelay.schedule = { _, fire in fire() }
    let text = long.surface.text as NSString
    let word = text.range(of: "offset")
    let field = text.range(of: ": Int")
    try flow(
      "editor_occurrences", size: NSSize(width: 1000, height: 480), render: { scene.view },
      steps: [
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
      ])
  }
}

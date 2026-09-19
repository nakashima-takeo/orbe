import SwiftUI
import XCTest

@testable import Orbe

/// 俯瞰とファイル内検索の flow（fixture は gallery と同じ `EditorCodeFixtures`）。長い文書でスクロールすると帯が動いて
/// ミニマップの窓がスライドし、ミニマップのクリックでその行が本文の中央に来る。⌘F で本文の右上にバーが出て、
/// needle で全一致に地が敷かれ現在の一致が選ばれ、Enter で次へ、Esc で地が消えて選択は残る。
extension DesignFlowSnapshotTests {
  func testEditorOverview() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorCodeFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    let tab = scene.tab
    let long = try tab.editor.open(scene.directory.appendingPathComponent("Long.swift"))
    let scroll = try XCTUnwrap(long.surface.view.subviews.first as? NSScrollView)
    let pane = scene.pane
    let lineHeight = EditorStyle.make().lineHeight
    pumpMain(until: { scene.isReady && long.baseline != nil }, "index 版が届く")
    try flow(
      "editor_overview", size: NSSize(width: 1000, height: 480), render: { scene.view },
      steps: [
        ("open", {}),  // 帯は上端、窓は先頭。追加の印が文書全体に散る
        (
          "scrolled",
          {  // 150 行目へ → 帯が下がり、ミニマップの窓が比例でスライドする
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 150 * lineHeight))
            scroll.reflectScrolledClipView(scroll.contentView)
          }
        ),
        (
          "clicked",
          {  // ミニマップの上の方をクリック → その行が本文の中央に来る
            pane.overview.jump(to: NSPoint(x: 50, y: 40))
          }
        ),
      ])
  }

  func testEditorFind() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorCodeFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    let pane = scene.pane
    pumpMain(until: { scene.isReady }, "index 版が届く")
    try flow(
      "editor_find", size: NSSize(width: 1000, height: 480), render: { scene.view },
      steps: [
        ("cmd_f", { pane.showSearch() }),  // 本文の右上（ミニマップの左）にバー
        (
          "typed",
          {  // needle → 全一致に地、キャレット以降で最初の一致が選択、件数 1/N
            pane.searchBar?.needle = "starts"
            pane.search.setNeedle("starts")
          }
        ),
        ("enter", { pane.search.next() }),  // 次の一致へ
        ("esc", { pane.closeSearch() }),  // 地が消え、選択は残る
      ])
  }
}

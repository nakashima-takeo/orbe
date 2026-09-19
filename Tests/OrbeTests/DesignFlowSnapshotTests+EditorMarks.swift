import SwiftUI
import XCTest

@testable import Orbe

/// 行の装備の flow（fixture は gallery と同じ `EditorCodeFixtures`）。印が git の状態と編集に追従する過程——
/// 開く（3 種の印）→ 行頭に 1 行挿す（追加の印が増える）→ `git add`（印が消える）→ 作業ツリーを書き戻す
/// （index との差が戻り、印が戻る）——と、タブで書かれた文書の線（空白だけの行も揃う）・横スクロール後の
/// 線と点と下線を撮る。
extension DesignFlowSnapshotTests {
  func testEditorDecor() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorCodeFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    let tab = scene.tab
    let go = try tab.editor.open(scene.directory.appendingPathComponent("main.go"))
    let scroll = try XCTUnwrap(go.surface.view.subviews.first as? NSScrollView)
    let pane = scene.pane
    let cell = (" " as NSString).size(withAttributes: [.font: EditorStyle.make().font]).width
    pumpMain(until: { scene.isReady && go.baseline != nil }, "index 版が届く")
    try flow(
      "editor_decor", size: NSSize(width: 1000, height: 480), render: { scene.view },
      steps: [
        ("tabs", {}),  // タブ 1 段 = 検出した単位（4 桁）。空白だけの行の線が隣と同じ x
        (
          "scrolled_right",
          {  // 8 行目の長い行で 20 桁ぶん右へ → 線・点・下線が付いてくる（印はガターに浮いたまま）
            scroll.contentView.scroll(to: NSPoint(x: 20 * cell, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
          }
        ),
        (
          "translucent",
          {  // 透過設定: ガターの地も面の地と同じ濃度の veil になり、本文はその下を通る
            pane.configure(
              translucency: ChromeTranslucency(
                effectiveOpacity: 0.6, translucent: true, blur: false),
              localization: LocalizationStore(language: .systemDefault),
              fontResolver: ChromeFontResolver(), sidebar: pane.sidebar)
          }
        ),
      ])
  }

  func testEditorMarks() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorCodeFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    let document = scene.document
    pumpMain(until: { scene.isReady }, "index 版が届く")
    let opened = document.hunks
    XCTAssertFalse(opened.isEmpty, "fixture の編集が効いている")
    let git = { (args: [String]) in _ = GitRunner.shared.runSync(args, cwd: scene.directory.path) }
    try flow(
      "editor_marks", size: NSSize(width: 1000, height: 480), render: { scene.view },
      steps: [
        ("open", {}),
        (
          "line_inserted",
          {  // 先頭に 1 行挿す → 追加の印が 1 行目に増え、他の印は 1 行下へ
            document.surface.responder.perform(Selector(("insertText:")), with: "// 行の装備\n")
            pumpMain(until: { document.hunks != opened }, "印が編集に追従する")
          }
        ),
        (
          "staged",
          {  // 端末での git add に相当 → index が本文と同じになり印が消える
            try? document.save()
            git(["add", "LineIndex.swift"])
            pumpMain(until: { document.hunks.isEmpty }, "git add で印が消える")
          }
        ),
        (
          "reverted_in_index",
          {  // index を元のコミットへ戻す → 本文との差が戻り印が戻る
            git(["reset", "-q", "HEAD", "--", "LineIndex.swift"])
            pumpMain(until: { !document.hunks.isEmpty }, "index が変われば印が戻る")
          }
        ),
      ])
  }
}

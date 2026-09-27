import SwiftUI
import XCTest

@testable import Orbe

/// エクスプローラーの下段のアウトラインの gallery（見本 `editor/ExplorerPanel.tsx` の下段・`editor/parts.tsx` の
/// SectionHead / SymbolChip の突合用）。骨の fixture の本物のソース（FileTree.swift）で、開いてキャレットのメソッドが
/// 選ばれた状態・絞り込み中・アウトラインを出せない文書（テキスト）。閉じた状態は骨の gallery（下端の見出し）。
extension DesignGallerySnapshotTests {
  func renderEditorOutlineSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    let size = NSSize(width: 1100, height: 640)
    let outline = scene.pane.outline

    scene.showOutline(caretAt: "func reveal(")
    pumpMain(until: { scene.isOutlineReady }, "アウトラインとカーソル追従が揃う")
    try writePNG(scene.view, size: size, name: "editor_outline.png", dir: dir)

    outline.setFilterText("rev")
    pumpMain(until: { scene.pane.document?.outlineFilter != nil }, "絞り込みが届く")
    pumpMain(until: { scene.isOutlineReady }, "絞り込みが揃う")
    try writePNG(scene.view, size: size, name: "editor_outline_filter.png", dir: dir)
    outline.clearFilter()

    _ = try scene.tab.editor.open(scene.directory.appendingPathComponent("notes.txt"))
    pumpMain(until: { outline.status == .unavailable }, "テキストはアウトラインを出せない")
    try writePNG(scene.view, size: size, name: "editor_outline_unavailable.png", dir: dir)
  }
}

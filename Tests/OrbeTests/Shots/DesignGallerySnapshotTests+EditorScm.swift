import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ソース管理パネルの gallery。fixture は本物の git の場で、
/// 変更の行（StateHooks.swift）を選んだ姿と、git 管理外のフォルダ・変更が無い作業ツリーの Changes の画面を dark / light で撮る。
/// 置き場の Changes の札（実行中の札 2 枚と失敗の札。`editor_scm_cards`）と、破棄の確認（1 件の `editor_scm_discard`・
/// ゴミ箱へ移す行を含む 3 件の `editor_scm_discard_many`）も撮る。
extension DesignGallerySnapshotTests {
  func renderEditorScmSnapshots(dir: URL) throws {
    try writePNG(
      ScmFixtures.cards(), size: NSSize(width: 700, height: 230), name: "editor_scm_cards.png",
      dir: dir)
    for (many, name) in [(false, "editor_scm_discard.png"), (true, "editor_scm_discard_many.png")] {
      try writePNG(
        ScmFixtures.discardConfirmation(many: many), size: NSSize(width: 1100, height: 420),
        name: name, dir: dir)
    }
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try ScmFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "行・グラフ・HEAD の push 済みが揃う")
    scene.panel.click(ScmRowID(section: .changes, path: "src/agent/StateHooks.swift"))
    try writePNG(
      scene.view, size: NSSize(width: 1100, height: 640), name: "editor_scm.png", dir: dir,
      until: { scene.isReady && scene.pane.showsDiff(of: "src/agent/StateHooks.swift") })

    try scene.git(["add", "-A"])
    try scene.git(["commit", "-qm", "gallery: すべてコミット"])
    pumpMain(
      until: { scene.panel.count == 0 && scene.panel.changes.staged.isEmpty }, "変更が無くなる")
    try writePNG(
      scene.view, size: NSSize(width: 1100, height: 640), name: "editor_scm_empty.png", dir: dir,
      until: { scene.panel.count == 0 && scene.panel.listState == .none })

    let plain = try ScmFixtures.unmanagedScene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { plain.cleanup() }
    plain.warmUp()
    pumpMain(until: { plain.panel.isManaged == false }, "git 管理外と分かる")
    try writePNG(
      plain.view, size: NSSize(width: 1100, height: 640), name: "editor_scm_nogit.png", dir: dir)
  }
}

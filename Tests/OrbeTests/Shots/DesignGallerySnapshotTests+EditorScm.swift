import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ソース管理パネルの gallery。fixture は本物の git の場で、
/// 変更の行（StateHooks.swift）を選んだ姿を dark / light で撮る。
extension DesignGallerySnapshotTests {
  func renderEditorScmSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try ScmFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "行・グラフ・HEAD の push 済みが揃う")
    scene.panel.select(ScmRowID(section: .changes, path: "src/agent/StateHooks.swift"))
    try writePNG(
      scene.view, size: NSSize(width: 1100, height: 640), name: "editor_scm.png", dir: dir,
      until: { scene.isReady })
  }
}

import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// ソース管理パネルの gallery。fixture は本物の git の場で、
/// 変更の行（StateHooks.swift）を選んだ姿と、レールの件数バッジを dark / light で撮る。
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
    try writePNG(
      railBadges, size: NSSize(width: 200, height: 120), name: "editor_scm_rail.png", dir: dir)
  }

  /// レールの件数バッジ: 1 桁から最も幅を取る「999+」まで。
  private var railBadges: some View {
    HStack(spacing: 12) {
      ForEach([3, 42, 999, 1000], id: \.self) { count in
        RailView(selection: .sourceControl, sourceControlCount: count, onSelect: { _ in })
      }
    }
    .padding(8)
  }
}

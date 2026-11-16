import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// PR のパネルの gallery（見本 `editor/PrReviewPanel.tsx`・`PrListPanel.tsx`・`Rail.tsx` の突合用）。fixture は本物の git の場と、
/// 見本の `editor/data.ts` の PR #131 を答える差し替えの出どころで、見本と同じく StateHooks.swift を選んだ姿と、PR が無いときの
/// 作成の入口を dark / light で撮る。
extension DesignGallerySnapshotTests {
  func renderEditorPullRequestSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let size = NSSize(width: 1100, height: 640)
    let scene = try PrFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "PR の中身と帯が揃う")
    scene.panel.select(.file("src/agent/StateHooks.swift"))
    try writePNG(
      scene.view, size: size, name: "editor_pr.png", dir: dir, until: { scene.isReady })
    let none = try PrFixtures.scene(
      .noPullRequest(published: true), queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { none.cleanup() }
    none.warmUp()
    pumpMain(until: { none.isReady }, "作成の入口の材料が揃う")
    try writePNG(
      none.view, size: size, name: "editor_pr_create.png", dir: dir, until: { none.isReady })
  }
}

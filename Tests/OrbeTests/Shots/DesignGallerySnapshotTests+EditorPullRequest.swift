import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// PR のパネルの gallery。fixture は本物の git の場と、PR #131 を答える差し替えの出どころで、StateHooks.swift を選んだ姿
/// （幅 1100 と、上のバーが PR の札を譲る幅 760）、その PR の diff のスレッド、PR が無いとき・表示できないとき（gh が認証
/// されていない）・問い合わせが失敗したときの本体と左の列を dark / light で撮る。
extension DesignGallerySnapshotTests {
  func renderEditorPullRequestSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let size = NSSize(width: 1100, height: 640)
    let scene = try PrFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "PR の中身と帯が揃う")
    scene.panel.click(.file("src/agent/StateHooks.swift"))
    try writePNG(
      scene.view, size: size, name: "editor_pr.png", dir: dir,
      until: { scene.isReady && scene.pane.showsDiff(of: "src/agent/StateHooks.swift") })
    try writePNG(
      scene.view, size: NSSize(width: 760, height: 480), name: "editor_pr_narrow.png", dir: dir,
      until: { scene.isReady && scene.pane.showsDiff(of: "src/agent/StateHooks.swift") })
    scene.openDiff()
    pumpMain(until: { scene.isDiffReady }, "PR の diff とスレッドが揃う")
    try writePNG(
      scene.view, size: NSSize(width: 1100, height: 760), name: "editor_pr_comments.png", dir: dir,
      until: { scene.isReady && scene.isDiffReady })
    let none = try PrFixtures.scene(
      .noPullRequest(published: true), queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { none.cleanup() }
    none.warmUp()
    pumpMain(until: { none.isReady }, "作成の入口の材料が揃う")
    try writePNG(
      none.view, size: size, name: "editor_pr_create.png", dir: dir, until: { none.isReady })
    for (answer, name) in [
      (PrFixtures.Answer.unavailable(.ghUnauthed), "editor_pr_unavailable.png"),
      (.failed(.unreachable), "editor_pr_failed.png"),
    ] {
      let blocked = try PrFixtures.scene(answer, queriesRoot: queriesRoot, in: TestScratch.caseDir)
      defer { blocked.cleanup() }
      blocked.warmUp()
      pumpMain(until: { blocked.isReady }, "\(name): 答えが出る")
      try writePNG(blocked.view, size: size, name: name, dir: dir, until: { blocked.isReady })
    }
  }
}

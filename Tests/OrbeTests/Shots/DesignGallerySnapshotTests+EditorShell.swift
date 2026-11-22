import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 骨込みのエディター面の gallery。広い幅（左の列 263）と狭い幅 360（左の列の表示幅が本体の最低幅 160 を残す 199 まで切り詰まり、
/// 上のバーから「⌥ 端末を表示」が消える）。status は git の子プロセス後に届くので、撮る前に揃うまで待つ。
extension DesignGallerySnapshotTests {
  func renderEditorShellSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    try writePNG(
      scene.view, size: NSSize(width: 1100, height: 640), name: "editor_shell.png", dir: dir)
    try writePNG(
      scene.view, size: NSSize(width: 360, height: 480), name: "editor_shell_narrow.png", dir: dir)
  }
}

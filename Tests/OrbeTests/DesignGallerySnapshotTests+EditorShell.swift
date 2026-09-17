import SwiftUI
import XCTest

@testable import Orbe

/// 骨込みのエディター面の gallery（見本 `EditorLayer.tsx` の edit シーン突合用）。広い幅（サイドバーあり）と
/// 狭い幅（サイドバーの表示幅が本体の最低幅を残すところまで切り詰まる）。status は git の子プロセス後に届くので、撮る前に揃うまで待つ。
extension DesignGallerySnapshotTests {
  func renderEditorShellSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot)
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    try writePNG(
      scene.view, size: NSSize(width: 1100, height: 640), name: "editor_shell.png", dir: dir)
    try writePNG(
      scene.view, size: NSSize(width: 640, height: 480), name: "editor_shell_narrow.png", dir: dir)
  }
}

import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// エディター面の gallery。
/// 空状態・字のボタン・入力欄の枠・差分のファイルの見出し（dark / light）・コードビュー（dark / light。一時 git リポジトリの中身で 3 種の印・丸点）。
extension DesignGallerySnapshotTests {
  func renderEditorSnapshots(dir: URL) throws {
    let stage = NSSize(width: 640, height: 480)
    try writePNG(EditorEmptyFixtures.gallery(), size: stage, name: "editor_empty.png", dir: dir)
    try writePNG(
      EditorTextButtonFixtures.gallery(), size: NSSize(width: 760, height: 120),
      name: "editor_text_button.png", dir: dir)
    try writePNG(
      EditorFieldFrameFixtures.gallery(), size: NSSize(width: 960, height: 120),
      name: "editor_field_frame.png", dir: dir)
    try writePNG(
      DiffFileHeaderFixtures.gallery(), size: NSSize(width: 820, height: 520),
      name: "editor_diff_header.png", dir: dir)
    // queries はテスト実行体の隣（`.build/<config>`）の資源バンドルから解く。
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let code = try EditorCodeFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { code.cleanup() }
    pumpMain(until: { code.isReady }, "index 版が届いて印が揃う")
    // 左の列 264 ＋ 行番号の列 69 の右、俯瞰（ミニマップとスクロールバー）の左に本文。最長行は右端で切れる。
    try writePNG(
      code.view, size: NSSize(width: 1000, height: 480), name: "editor_code.png", dir: dir)
  }
}

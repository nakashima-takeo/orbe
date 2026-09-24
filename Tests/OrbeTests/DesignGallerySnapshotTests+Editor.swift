import SwiftUI
import XCTest

@testable import Orbe

/// エディター面の gallery（見本 `editor/EmptyView.tsx`・`CodeView.tsx`・`Chrome.tsx` の位置ドット突合用）。
/// 空状態（dark / light）・コードビュー（dark / light。一時 git リポジトリの中身で 3 種の印・インデント線・
/// 丸点・URL 下線）と、タブ行右端の位置ドット 3 態
/// （端末のみ・分割で端末焦点・エディターのみ）。
extension DesignGallerySnapshotTests {
  func renderEditorSnapshots(dir: URL) throws {
    let stage = NSSize(width: 640, height: 480)
    try writePNG(EditorEmptyFixtures.gallery(), size: stage, name: "editor_empty.png", dir: dir)
    // queries はテスト実行体の隣（`.build/<config>`）の資源バンドルから解く。
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let code = try EditorCodeFixtures.scene(queriesRoot: queriesRoot)
    defer { code.cleanup() }
    pumpMain(until: { code.isReady }, "index 版が届いて印が揃う")
    // サイドバー 240 ＋ レール 36 ＋ ガター 69 の右、俯瞰（ミニマップとスクロールバー）の左に本文。最長行は右端で切れる。
    try writePNG(
      code.view, size: NSSize(width: 1000, height: 480), name: "editor_code.png", dir: dir)

    let rowStage = NSSize(width: 640, height: 520)
    let cases: [(String, FaceGeometry.FaceDots)] = [
      ("statusrow_facedots_terminal", .init(editor: .off, terminal: .focus)),
      ("statusrow_facedots_split", .init(editor: .on, terminal: .focus)),
      ("statusrow_facedots_editor", .init(editor: .focus, terminal: .off)),
    ]
    for (name, dots) in cases {
      let model = StatusRowModel()
      model.update(
        StatusRowModel.Snapshot(
          workspace: "orbe",
          strip: TabStrip(titles: ["src/renderer", "docs"], glyphs: [.working, nil]),
          active: 0, location: .cwd("~/dev/orbe"), faceDots: dots, rollup: [("working", 1)]))
      try writePNG(
        ZStack(alignment: .top) {
          BackgroundGlow()
          StatusRowView(model: model).frame(width: rowStage.width, height: Chrome.barHeight)
        }
        .frame(width: rowStage.width, height: rowStage.height, alignment: .top),
        size: rowStage, name: "\(name).png", dir: dir)
    }
  }
}

import OrbeEditorCore
import SwiftUI
import XCTest

@testable import Orbe

/// 検索パネルの gallery（見本 `editor/SearchPanel.tsx` の突合用）。骨の fixture のリポジトリを実際に探した結果で、
/// 結果あり（Aa を有効・2 つ目の一致を選んで開いた状態。本文にも一致の地と現在の一致）・0 件・正規表現のエラー・打ち切り。
extension DesignGallerySnapshotTests {
  func renderEditorSearchSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    let size = NSSize(width: 1100, height: 640)
    let search = scene.pane.projectSearch
    func run(_ query: SearchQuery) {
      scene.search(query)
      pumpMain(until: { scene.isSearchDone }, "検索が終わる")
    }

    run(SearchQuery(pattern: "document", matchCase: true))
    let second = try XCTUnwrap(search.rows.dropFirst(2).first?.id)
    search.click(second)
    try writePNG(scene.view, size: size, name: "editor_search.png", dir: dir)

    run(SearchQuery(pattern: "zzqqxx_nothing"))
    try writePNG(scene.view, size: size, name: "editor_search_empty.png", dir: dir)

    run(SearchQuery(pattern: "(unclosed", isRegex: true))
    try writePNG(scene.view, size: size, name: "editor_search_invalid.png", dir: dir)

    run(SearchQuery(pattern: ".", isRegex: true))
    try writePNG(scene.view, size: size, name: "editor_search_limited.png", dir: dir)
  }
}

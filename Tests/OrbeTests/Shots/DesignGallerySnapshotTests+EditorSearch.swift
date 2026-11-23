import OrbeEditorCore
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 検索パネルの gallery。骨の fixture のリポジトリを実際に探した結果で、
/// 結果あり（Aa を有効・2 つ目の一致を選んで開いた状態。本文にも一致の地と現在の一致。見出しは「ツリーに戻る esc」）・全部を
/// 畳んだ見出し（すべて展開）・2 秒を超えた検索の見出し（「止める esc」と進捗の線）・狭い幅（キーの札が落ちる・さらに狭いと
/// 右から切れる）・0 件・正規表現のエラー・打ち切り。
extension DesignGallerySnapshotTests {
  func renderEditorSearchSnapshots(dir: URL) throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
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
    XCTAssertGreaterThan(search.rowCount, 2)
    search.click(search.row(at: 2).id)
    try writePNG(scene.view, size: size, name: "editor_search.png", dir: dir)

    search.toggleCollapseAll()
    try writePNG(scene.view, size: size, name: "editor_search_collapsed.png", dir: dir)
    search.toggleCollapseAll()

    // git grep を門で止めて検索を走らせたままにし、2 秒を超えた段へすぐ進めて撮る。
    let gate = try GrepGate(directory: scene.directory) { fifo in
      (try? FixtureGit(directory: scene.directory)(["config", "core.excludesFile", fifo])) != nil
    }
    let slowSchedule = search.slowDelay.schedule
    search.slowDelay.schedule = { _, fire in fire() }
    search.search()
    search.slowDelay.schedule = slowSchedule
    pumpMain(until: { GrepGate.isGrepRunning }, "git が門で待つ")
    nextTurn()
    XCTAssertTrue(search.stopsOnDismiss, "2 秒を超えた検索")
    try writePNG(scene.view, size: size, name: "editor_search_slow.png", dir: dir)
    gate.close()
    pumpMain(until: { scene.isSearchDone }, "検索が終わる")

    try writePNG(
      scene.view, size: NSSize(width: 320, height: 480), name: "editor_search_narrow.png", dir: dir)
    try writePNG(
      scene.view, size: NSSize(width: 290, height: 480), name: "editor_search_narrowest.png",
      dir: dir)

    run(SearchQuery(pattern: "zzqqxx_nothing"))
    try writePNG(scene.view, size: size, name: "editor_search_empty.png", dir: dir)

    run(SearchQuery(pattern: "(unclosed", isRegex: true))
    try writePNG(scene.view, size: size, name: "editor_search_invalid.png", dir: dir)

    run(SearchQuery(pattern: ".", isRegex: true))
    try writePNG(scene.view, size: size, name: "editor_search_limited.png", dir: dir)
  }
}

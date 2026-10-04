import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 検索結果の ↑↓ で一致を仮のタブで開くときの main の仕事の計測。`ORBE_EDITOR_PERF=1` のときだけ走る（時間はマシンと
/// 環境で変わるので通常のテストでは見ない）。結果は `PERF` で始まる行に出す。
///
/// 1MB の Swift のファイル 30 個（どれも先頭に一致 1 件）の結果の列で、実際の押しっぱなしの並び（リピートでない押下 1 つ →
/// 初期遅延 0.5 秒 → 30ms ごとのリピート 2 秒）を流し、キー 1 回ごとの main の時間（押下と、続く run loop の 1 周）と開いた
/// 回数を見る。開くキーの時間は、仮のタブを入れ替える開きと、入れ替えの無い開き（今の「結果をクリックして開く」）で比べる。
@MainActor
final class ProjectSearchArrowPerfTests: OrbeTestCase {
  private struct Hosted {
    let repo: TempGitRepo
    let tab: TerminalTab
    let window: NSWindow
    @MainActor var pane: EditorPaneView { tab.view.editor }
    @MainActor var search: ProjectSearch { pane.projectSearch }
  }

  private static let files = 30

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["ORBE_EDITOR_PERF"] == "1", "ORBE_EDITOR_PERF=1 で走る")
  }

  private func host() throws -> Hosted {
    let repo = try TempGitRepo(name: "orbe-arrow-perf")
    addTeardownBlock { repo.cleanup() }
    let body = EditorTypingPerfTests.swiftSource(bytes: 1_000_000)
    for index in 0..<Self.files {
      try repo.write(String(format: "f%02d.swift", index), "// needle\n" + body)
    }
    let queries = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let tab = TerminalTab(
      cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: queries))
    let window = hostEditor(tab, width: 1200, height: 800)
    window.appearance = NSAppearance(named: .darkAqua)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let hosted = Hosted(repo: repo, tab: tab, window: window)
    hosted.pane.showProjectSearch(seed: nil)
    hosted.search.setPattern("needle")
    hosted.search.search()
    pumpMain(until: { hosted.search.phase == .done }, timeout: 60, "検索が終わる")
    pumpMain(until: { hosted.pane.searchResults.window != nil }, "結果の列が出る")
    return hosted
  }

  /// `body` の間の開きの main の時間（ms、壁時計）を 1 回ずつ数える。
  private func countingOpens(_ search: ProjectSearch, _ body: (() -> Int) -> Void) -> [Double] {
    var times: [Double] = []
    let open = search.onOpen
    defer { search.onOpen = open }
    search.onOpen = { id, opening in
      let began = CACurrentMediaTime()
      open(id, opening)
      times.append((CACurrentMediaTime() - began) * 1000)
    }
    body { times.count }
    return times
  }

  /// 押下 1 回と、続く run loop の 1 周（列の写し・描画の準備）の main の時間（ms、壁時計）。
  private func press(_ list: RowListView<SearchResultsSource>, isRepeat: Bool) -> Double {
    let down = NSEvent.key(
      String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!), [], isRepeat: isRepeat)
    let began = CACurrentMediaTime()
    list.keyDown(with: down)
    RunLoop.main.run(mode: .default, before: Date())
    return (CACurrentMediaTime() - began) * 1000
  }

  private func idle(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  /// 押しっぱなし 1 回分（押下 → 初期遅延 `delay` 秒 → 30ms ごとのリピート `repeats` 回 → 離す）。開かなかったキーの時間と、
  /// 開いた回数。
  private func hold(
    _ hosted: Hosted, repeats: Int, delay: TimeInterval = 0.5, while running: () -> Bool = { true }
  ) -> (quiet: [Double], opens: Int) {
    let list = hosted.pane.searchResults.list
    var quiet: [Double] = []
    let opens = countingOpens(hosted.search) { opened in
      let time = press(list, isRepeat: false)
      if opened() == 0 { quiet.append(time) }
      idle(delay)
      for _ in 0..<repeats where running() {
        let began = Date()
        let before = opened()
        let time = press(list, isRepeat: true)
        if opened() == before { quiet.append(time) }
        RunLoop.main.run(until: began.addingTimeInterval(0.03))
      }
      idle(0.3)
    }
    return (quiet, opens.count)
  }

  func testHoldingDownOpensTwiceAndQuietKeysStayWithinAFrame() throws {
    let hosted = try host()
    hosted.window.makeFirstResponder(hosted.pane.searchResults.list)
    for round in 0..<3 {
      hosted.search.select(ProjectSearch.RowID(path: "f00.swift", match: nil))
      idle(0.2)
      let (quiet, opens) = hold(hosted, repeats: 66)
      reportPerf("1MB×\(Self.files)", "arrow-hold quiet keys (round \(round))", quiet, digits: 2)
      print("PERF", "1MB×\(Self.files)", "arrow-hold opens (round \(round))", opens)
      XCTAssertEqual(opens, 2, "押しっぱなしで開くのは押し始めと離した後の 2 回")
    }
    // 比べる基準: 開かずに選択だけを動かす（文書の無い面で、開く口を空にする）。開かないキーの時間はこれと同じ仕事。
    let open = hosted.search.onOpen
    hosted.search.onOpen = { _, _ in }
    defer { hosted.search.onOpen = open }
    for document in hosted.tab.editor.documents { hosted.tab.editor.close(document) }
    hosted.search.select(ProjectSearch.RowID(path: "f00.swift", match: nil))
    idle(0.2)
    let reference = hold(hosted, repeats: 66).quiet
    reportPerf(
      "1MB×\(Self.files)", "arrow-hold keys without opening (reference)", reference, digits: 2)
  }

  /// 仮のタブを入れ替える開きと、入れ替えの無い開き（文書の無い面でクリックして開く）の main の時間。
  func testReplacingThePreviewCostsAboutTheSameAsAPlainOpen() throws {
    let hosted = try host()
    let editor = hosted.tab.editor
    let match = { (index: Int) in
      ProjectSearch.RowID(path: String(format: "f%02d.swift", index), match: 0)
    }
    let click = { (index: Int) -> Double in
      let began = CACurrentMediaTime()
      hosted.search.click(match(index))
      RunLoop.main.run(mode: .default, before: Date())
      return (CACurrentMediaTime() - began) * 1000
    }
    var plain: [Double] = []
    for index in 0..<10 {
      for document in editor.documents { editor.close(document) }
      idle(0.2)
      plain.append(click(index))
    }
    var replacing: [Double] = []
    for index in 10..<20 {
      idle(0.2)
      XCTAssertNotNil(editor.preview, "前提: 入れ替える仮のタブがある")
      replacing.append(click(index))
    }
    XCTAssertEqual(editor.documents.count, 1, "入れ替えでタブは増えない")
    reportPerf("1MB", "open by click (no preview to replace)", plain, digits: 1)
    reportPerf("1MB", "open by click (replacing the preview)", replacing, digits: 1)
  }

  /// 検索の最中（git grep が走り結果が届いている間）に押しっぱなしにしても、開かないキーは 1 コマに収まる（検索は短いので
  /// 初期遅延を置かずにリピートを流す）。
  func testHoldingDownWhileSearching() throws {
    let hosted = try host()
    hosted.window.makeFirstResponder(hosted.pane.searchResults.list)
    var quiet: [Double] = []
    for _ in 0..<5 {
      hosted.search.search()
      quiet += hold(hosted, repeats: 66, delay: 0, while: { hosted.search.isSearching }).quiet
      pumpMain(until: { !hosted.search.isSearching }, timeout: 60)
    }
    reportPerf("1MB×\(Self.files)", "arrow-hold quiet keys while searching", quiet, digits: 2)
  }
}

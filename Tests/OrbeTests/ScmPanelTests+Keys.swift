import XCTest

@testable import Orbe

/// 列のキー——↑↓ は区分見出しとファイル行だけを渡り（グラフの行には止まらない）、ファイル行でだけ仮で開く。← → Enter は
/// 見出しの開閉と見出し・ファイル行の行き来、Enter はファイル行を普通のタブで開く。⌘↑ は先頭の行から、欄が見えているときだけ
/// 欄へ戻る。
///
/// 壊れると何が起きるか。↓ がグラフのブランチやコミットの行に止まり、Enter も ← → も効かない行に選択が残る。見出しへ動いた
/// だけで diff が開く。Enter で開いても焦点が列に残る。畳んだ区分「ソース管理」へ ⌘↑ が焦点を送り、焦点の要求が残って次に
/// 区分「ソース管理」を開いたとき欄が焦点を奪う。
extension ScmPanelTests {
  /// 開いた diff と開き方。
  typealias Opened = (key: EditorDiff.Key, opening: ScmPanel.Opening)

  /// ステージ済み s.txt、変更 a.txt（編集）・n.txt（未追跡）、グラフ（ブランチと 1 コミット）の出たパネル。キーの開きは
  /// 窓を待たずにそのつど開く。開いた行を記録する。
  private func keysPanel() throws -> () -> [Opened] {
    try repo.write("s.txt", "s\n")
    XCTAssertTrue(repo.git(["add", "s.txt"]).isSuccess)
    try repo.write("a.txt", "edited\n")
    try repo.write("n.txt", "new\n")
    show(
      until: { panel in
        panel.changes.staged.count == 1 && panel.changes.changes.count == 2
          && panel.graph != nil
          && panel.layout.items.contains { if case .commit = $0 { true } else { false } }
      }, "2 区分とグラフの行")
    panel.navigation.delay.schedule = { _, fire in fire() }
    var opened: [Opened] = []
    panel.onOpenDiff = { key, opening in opened.append((key, opening)) }
    return { opened }
  }

  private func id(_ section: ScmSection, _ path: String? = nil) -> ScmRowID {
    ScmRowID(section: section, path: path)
  }

  private func rebuilt(_ message: String, _ ready: @escaping (ScmPanel) -> Bool) {
    pumpMain(until: { ready(self.panel) }, message)
  }

  /// ↓ は未選択なら先頭から、区分見出しとファイル行だけを順に渡り、グラフの見出しの先（ブランチ・コミット）へは進まない。
  /// ファイル行へ動いたときだけ、その区分の diff を仮で開く。
  func testArrowsCrossOnlyHeadersAndFilesAndPreviewTheFilesTheyReach() throws {
    let opened = try keysPanel()
    var visited: [ScmRowID?] = []
    for _ in 0..<7 {
      panel.moveSelection(by: 1, isRepeat: false)
      visited.append(panel.selection)
    }
    XCTAssertEqual(
      visited,
      [
        id(.staged), id(.staged, "s.txt"), id(.changes), id(.changes, "a.txt"),
        id(.changes, "n.txt"), id(.graph), id(.graph),
      ])
    XCTAssertEqual(opened().map(\.key.path), ["s.txt", "a.txt", "n.txt"], "見出しでは開かない")
    XCTAssertEqual(opened().map(\.key.kind), [.staged, .workingTree, .workingTree])
    XCTAssertTrue(opened().allSatisfy { $0.opening == .browse })
  }

  /// ← はファイル行から見出しへ、開いた見出しなら畳む。→ は畳んだ見出しを開き、開いた見出しなら最初のファイル行へ動いて
  /// 仮で開く。Enter は見出しなら開閉、ファイル行なら普通のタブで開く。
  func testLeftRightAndEnterMoveBetweenAHeaderAndItsFilesAndToggleIt() throws {
    let opened = try keysPanel()
    panel.select(id(.changes, "n.txt"))
    panel.moveLeft()
    XCTAssertEqual(panel.selection, id(.changes))
    panel.moveLeft()
    rebuilt("← で畳む") { $0.layout.fileRanges[.changes]?.isEmpty == true }
    panel.moveRight(isRepeat: false)
    rebuilt("→ で開く") { $0.layout.fileRanges[.changes]?.isEmpty == false }
    XCTAssertEqual(panel.selection, id(.changes), "開くだけでは動かない")
    panel.moveRight(isRepeat: false)
    XCTAssertEqual(panel.selection, id(.changes, "a.txt"))
    XCTAssertEqual(opened().last?.opening, .browse)

    panel.activateSelection()
    XCTAssertEqual(opened().last?.key.path, "a.txt")
    XCTAssertEqual(opened().last?.key.kind, .workingTree)
    XCTAssertEqual(opened().last?.opening, .commit, "Enter は普通のタブで本文へ")
    let count = opened().count
    panel.select(id(.staged))
    panel.activateSelection()
    rebuilt("Enter で畳む") { $0.layout.fileRanges[.staged]?.isEmpty == true }
    panel.activateSelection()
    rebuilt("Enter で開く") { $0.layout.fileRanges[.staged]?.isEmpty == false }
    XCTAssertEqual(opened().count, count, "見出しの Enter は開かない")
  }

  /// ⌘↑ は先頭の行か未選択のときだけ欄へ焦点を求め、区分「ソース管理」を畳んで欄が隠れていれば求めない。
  func testCommandUpReturnsToTheMessageOnlyFromTheTopWhileItIsShown() throws {
    _ = try keysPanel()
    panel.select(id(.staged, "s.txt"))
    panel.returnToMessageIfAtTop()
    XCTAssertNil(panel.focusRequest, "先頭でなければ戻らない")

    panel.isControlsOpen = false
    panel.select(id(.staged))
    panel.returnToMessageIfAtTop()
    XCTAssertNil(panel.focusRequest, "欄が隠れていれば戻らない")

    panel.isControlsOpen = true
    panel.returnToMessageIfAtTop()
    XCTAssertEqual(panel.focusRequest, .message)
    panel.focusRequestDidApply()
    panel.select(nil)
    panel.returnToMessageIfAtTop()
    XCTAssertEqual(panel.focusRequest, .message, "未選択からも戻る")
  }
}

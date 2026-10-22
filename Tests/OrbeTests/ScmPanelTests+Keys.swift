import XCTest

@testable import Orbe

/// 変更の列のキー——↑↓ は子の見出しとファイル行を渡り（グラフは別の列で、キーでは入らない）、ファイル行でだけ仮で開く。
/// ← → Enter は見出しの開閉と見出し・ファイル行の行き来、Enter はファイル行を普通のタブで開く。⌘↑ は先頭の行から欄へ戻る。
/// 親「ソース管理」を畳むと、当てていない焦点の要求を捨て、焦点を本文へ移させてから畳む。
///
/// 壊れると何が起きるか。↓ が列の末尾を越えて選択を失う。見出しへ動いただけで diff が開く。Enter で開いても焦点が列に残る。
/// 親を畳んだ後に残った焦点の要求が、次に親を開いたとき欄の焦点を奪う。親を畳んだ瞬間に欄・列が窓から外れ、キーがどこにも
/// 届かなくなる。
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
        panel.changes.staged.count == 1 && panel.layout.items.count == 5
          && panel.graphLayout.items.contains { if case .commit = $0 { true } else { false } }
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

  /// ↓ は未選択なら先頭から、子の見出しとファイル行を順に渡り、末尾で止まる。ファイル行へ動いたときだけ、その区分の diff を
  /// 仮で開く。
  func testArrowsCrossHeadersAndFilesAndPreviewTheFilesTheyReach() throws {
    let opened = try keysPanel()
    var visited: [ScmRowID?] = []
    for _ in 0..<6 {
      panel.moveSelection(by: 1, isRepeat: false, in: panel.layout)
      visited.append(panel.selection)
    }
    XCTAssertEqual(
      visited,
      [
        id(.staged), id(.staged, "s.txt"), id(.changes), id(.changes, "a.txt"),
        id(.changes, "n.txt"), id(.changes, "n.txt"),
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
    panel.moveRight(isRepeat: false, in: panel.layout)
    rebuilt("→ で開く") { $0.layout.fileRanges[.changes]?.isEmpty == false }
    XCTAssertEqual(panel.selection, id(.changes), "開くだけでは動かない")
    panel.moveRight(isRepeat: false, in: panel.layout)
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

  /// ⌘↑ は先頭の行か未選択のときだけ欄へ焦点を求める。
  func testCommandUpReturnsToTheMessageOnlyFromTheTop() throws {
    _ = try keysPanel()
    panel.select(id(.staged, "s.txt"))
    panel.returnToMessageIfAtTop()
    XCTAssertNil(panel.focusRequest, "先頭でなければ戻らない")

    panel.select(id(.staged))
    panel.returnToMessageIfAtTop()
    XCTAssertEqual(panel.focusRequest, .message)
    panel.focusRequestDidApply()
    panel.select(nil)
    panel.returnToMessageIfAtTop()
    XCTAssertEqual(panel.focusRequest, .message, "未選択からも戻る")
  }

  /// 親を畳む口は、畳む前に焦点を本文へ移させ（欄と列がまだ窓に居るうち）、当てていない焦点の要求を捨てる。選択・子の区分の
  /// 開閉は残り、開けば元のまま。
  func testClosingTheRepositoryLetsTheFocusLeaveFirstAndDropsTheFocusRequest() throws {
    _ = try keysPanel()
    var order: [String] = []
    panel.onRepositoryWillClose = { [unowned self] in
      order.append(panel.isRepositoryOpen ? "leave while open" : "leave after close")
    }
    panel.select(id(.changes, "a.txt"))
    panel.toggle(.staged)
    panel.requestFocus(.message)
    panel.setRepositoryOpen(false)
    XCTAssertEqual(order, ["leave while open"])
    XCTAssertFalse(panel.isRepositoryOpen)
    XCTAssertNil(panel.focusRequest, "当てていない要求は捨てる")

    panel.setRepositoryOpen(false)
    XCTAssertEqual(order.count, 1, "畳んだまま畳んでも呼ばない")
    panel.setRepositoryOpen(true)
    XCTAssertEqual(panel.selection, id(.changes, "a.txt"), "選択は残る")
    XCTAssertFalse(panel.isOpen(.staged), "子の区分の開閉は残る")
    XCTAssertEqual(order.count, 1, "開くときは呼ばない")
  }
}

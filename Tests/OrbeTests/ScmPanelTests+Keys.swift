import XCTest

@testable import Orbe

/// 変更の列のキー——↑↓ は子の見出しとファイル行を渡り（グラフは別の列で、キーでは入らない）、ファイル行でだけ仮で開く。
/// ← → Enter は見出しの開閉と見出し・ファイル行の行き来、Enter はファイル行を普通のタブで開く。⌘↑ は先頭の行から欄へ戻る。
/// 押し続けた ↑↓ は離すまで開かず、待っている開きは人の注意が列から移ったら捨てる。
///
/// 壊れると何が起きるか。↓ が列の末尾を越えて選択を失う。見出しへ動いただけで diff が開く。Enter で開いても焦点が列に残る。
/// 押し続けると 1 行ごとに diff を開いて選択の移動が遅れる・離しても最後の行が開かない。本文へ移った後や Enter で開いた
/// 後に、待っていた前の行の diff が開いて入れ替わる。
extension ScmPanelTests {
  /// 開いた diff と開き方。
  typealias Opened = (key: EditorDiff.Key, opening: ScmPanel.Opening)

  /// ステージ済み s.txt、変更 a.txt（編集）・n.txt（未追跡）の出たパネル。キーの開きの窓はすぐ閉じる（押し続けている
  /// 間の待ちは窓に依らない）。開いた行を記録する。
  private func keysPanel() throws -> () -> [Opened] {
    try repo.write("s.txt", "s\n")
    XCTAssertTrue(repo.git(["add", "s.txt"]).isSuccess)
    try repo.write("a.txt", "edited\n")
    try repo.write("n.txt", "new\n")
    show(until: { $0.changes.staged.count == 1 && $0.layout.items.count == 5 }, "2 区分の行")
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

  /// 列で押し続けた ↓ は、押し始めの行だけをすぐ開き、押している間（キーリピート）は開かず、離したら最後のファイル行だけを
  /// 仮で開く。
  func testHoldingAnArrowInTheListOpensOnlyTheFirstAndTheLastFile() throws {
    let opened = try keysPanel()
    let list = ScmListSource(panel: panel)
    panel.select(id(.changes))

    list.perform(RowListKey(action: .down, isRepeat: false), in: panel.layout)
    XCTAssertEqual(opened().map(\.key.path), ["a.txt"], "押し始めはすぐ開く")
    list.perform(RowListKey(action: .down, isRepeat: true), in: panel.layout)
    XCTAssertEqual(panel.selection, id(.changes, "n.txt"))
    XCTAssertEqual(opened().count, 1, "押している間は開かない")
    list.keyDidRelease()
    XCTAssertEqual(opened().map(\.key.path), ["a.txt", "n.txt"], "離したら最後の行")
    XCTAssertEqual(opened().last?.opening, .browse)
  }

  /// 押し続けて待っている開きは、列から焦点が外れた・Enter で開いた・パネルが隠れたら捨てる（離しても前の行が開かない）。
  func testAPendingArrowOpenIsDroppedWhenAttentionLeavesTheList() throws {
    let opened = try keysPanel()
    let list = ScmListSource(panel: panel)
    let enter = RowListKey(action: .enter, isRepeat: false)
    let leaves: [(String, () -> Void)] = [
      ("列から焦点が外れた", { list.focusDidChange(false) }),
      ("Enter", { list.perform(enter, in: self.panel.layout) }),
      ("パネルが隠れた", { self.panel.isShown = false }),
    ]
    for (name, leave) in leaves {
      panel.select(id(.changes, "n.txt"))
      list.perform(RowListKey(action: .up, isRepeat: true), in: panel.layout)
      XCTAssertEqual(panel.selection, id(.changes, "a.txt"), name)
      leave()
      let count = opened().count
      list.keyDidRelease()
      XCTAssertEqual(opened().count, count, "\(name): 待っていた開きは走らない")
    }
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

  /// 当てられないまま隠れた焦点の要求は捨てる（後で欄が現れても、面の外の焦点を奪わない）。
  func testAFocusRequestLeftUnappliedIsDroppedWhenThePanelHides() throws {
    show(until: { $0.isManaged == true }, "パネル")
    panel.requestFocus(.message)
    panel.isShown = false
    XCTAssertNil(panel.focusRequest)
  }
}

import AppKit
import XCTest

@testable import Orbe

/// 結果の列で ↓ を押し続けている間（か離した直後）に、人が結果の外——ファイルタブ・タブの ×・エクスプローラーの行——を
/// 押したら、待っていた一致は開かない。押したものが見え、焦点も押した先のまま。
///
/// 壊れると何が起きるか。↓ でたどった直後にタブを押すと、押したファイルが一瞬見えた後で待っていた一致に入れ替わり、焦点も
/// その本文へ奪われる。
extension ProjectSearchPaneTests {
  /// a.txt・b.txt に一致、z.txt・x.txt は一致なしで普通のタブで開いておく。窓は物理画面の外へ並べる（`sendEvent` は
  /// ordered-in の窓にしか配送しない）。結果の列で ↓ を押し続け、b.txt の一致を待たせた状態で返す（`release` があれば離して
  /// その秒数だけ置く）。
  private func holding(releasedFor release: TimeInterval?) throws -> Hosted {
    let hosted = try host([
      "a.txt": "needle\n", "b.txt": "needle\n", "x.txt": "xxx\n", "z.txt": "zzz\n",
    ])
    hosted.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    hosted.window.orderFront(nil)
    _ = try open(hosted, "z.txt")
    _ = try open(hosted, "x.txt")
    searchAll(hosted, "needle")
    let list = try list(hosted)
    hosted.window.makeFirstResponder(list)
    let arrow = String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)
    hosted.search.select(RowID(path: "a.txt", match: nil))
    list.keyDown(with: .key(arrow, []))
    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("a.txt"), "前提: 押し始めは開く")
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    list.keyDown(with: .key(arrow, [], isRepeat: true))
    list.keyDown(with: .key(arrow, [], isRepeat: true))
    XCTAssertEqual(hosted.search.selection, RowID(path: "b.txt", match: 0), "前提: b.txt を待っている")
    if let release {
      list.keyUp(with: .keyRelease(arrow))
      RunLoop.main.run(until: Date().addingTimeInterval(release))
    }
    hosted.pane.layoutSubtreeIfNeeded()
    _ = try probe(hosted.pane) { _ in hosted.pane.shell.tabs.count == 3 }
    return hosted
  }

  /// ファイルタブ `name` の名前の上（面の座標）。
  private func tabPoint(_ hosted: Hosted, _ name: String) throws -> NSPoint {
    let index = try XCTUnwrap(hosted.pane.shell.tabs.firstIndex { $0.name == name })
    let slot = fileTabSlotCenter(hosted.pane, index)
    return NSPoint(x: slot.x - 30, y: slot.y)
  }

  /// 押したものが見えたまま、待っていた一致は開かない。
  private func assertTheWaitingMatchStaysClosed(
    _ hosted: Hosted, shows url: URL, _ message: String, line: UInt = #line
  ) {
    pumpMain(until: { hosted.pane.document?.url == url }, "\(message): 押したものが見える", line: line)
    let responder = hosted.window.firstResponder
    XCTAssertTrue(
      holds(for: 0.3) {
        hosted.pane.document?.url == url && hosted.window.firstResponder === responder
      }, "\(message): 待っていた一致に入れ替わらず、焦点も動かない", line: line)
    XCTAssertFalse(
      hosted.tab.editor.documents.contains { $0.url == hosted.repo.url("b.txt") },
      "\(message): 待っていた一致は開かない", line: line)
  }

  func testPressingAFileTabWhileHoldingDownDropsTheWaitingOpen() throws {
    for release in [nil, 0.03] as [TimeInterval?] {
      let hosted = try holding(releasedFor: release)
      let z = hosted.repo.url("z.txt")
      try click(hosted.pane, at: tabPoint(hosted, "z.txt"))
      assertTheWaitingMatchStaysClosed(
        hosted, shows: z, release == nil ? "押したままタブ" : "離した 30ms 後にタブ")
    }
  }

  func testClosingATabWhileHoldingDownDropsTheWaitingOpen() throws {
    for release in [nil, 0.03] as [TimeInterval?] {
      let hosted = try holding(releasedFor: release)
      let x = hosted.repo.url("x.txt")
      let index = try XCTUnwrap(hosted.pane.shell.tabs.firstIndex { $0.id == x })
      try click(hosted.pane, at: fileTabSlotCenter(hosted.pane, index))
      pumpMain(until: { !hosted.tab.editor.documents.contains { $0.url == x } }, "× で閉じる")
      assertTheWaitingMatchStaysClosed(
        hosted, shows: hosted.repo.url("a.txt"), release == nil ? "押したまま ×" : "離した 30ms 後に ×")
    }
  }

  func testPressingATreeRowWhileHoldingDownDropsTheWaitingOpen() throws {
    for release in [nil, 0.03] as [TimeInterval?] {
      let hosted = try holding(releasedFor: release)
      let z = hosted.repo.url("z.txt")
      hosted.pane.shell.selectPanel(.files)
      let index = try XCTUnwrap(
        hosted.pane.tree.rows.firstIndex { $0.name == "z.txt" }, "ツリーに z.txt の行")
      let row = NSPoint(
        x: Theme.Layout.editorRail + 80,
        y: Theme.Layout.editorPanelHeader + Theme.Layout.editorRow * (CGFloat(index) + 1.5))
      _ = try probe(hosted.pane) { _ in hosted.pane.tree.rows.count >= 4 }
      try click(hosted.pane, at: row)
      assertTheWaitingMatchStaysClosed(
        hosted, shows: z, release == nil ? "押したままツリーの行" : "離した 30ms 後にツリーの行")
    }
  }
}

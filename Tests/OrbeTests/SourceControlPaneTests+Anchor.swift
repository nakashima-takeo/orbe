import AppKit
import XCTest

@testable import Orbe

extension SourceControlPaneTests {
  /// 行の ＋ をポインタを動かさずに同じ位置で続けて押すと、押すたびに同じ区分の次の行（最後なら前の行）がポインタの下に
  /// 来て、次々にステージされる——上に「ステージされている変更」が現れて行が下がっても、短い列で送れなくても。
  func testPressingTheSameSpotStagesTheFollowingRowsOneAfterAnother() throws {
    let repo = try TempGitRepo()
    for name in ["x1.txt", "x2.txt", "x3.txt", "x4.txt"] { try repo.write(name, "x\n") }
    let hosted = host(repo)
    let scm = hosted.scm
    pumpMain(until: { scm.changes.changes.count == 4 }, "変更の行")
    let first = try row(hosted, .changes, "x2.txt")
    pumpMain(until: { self.slot(first, in: hosted.pane) != nil }, timeout: 3, "載っている列に行")
    let slot = try XCTUnwrap(slot(first, in: hosted.pane))
    let list = try XCTUnwrap(slot.superview as? RowListView<ScmListSource>)
    let plus = try XCTUnwrap(slot.buttonRects().first { $0.0.control == .stage }?.1)
    let spot = slot.convert(NSPoint(x: plus.midX, y: plus.midY), to: nil)

    var staged: [String] = []
    for expected in ["x2.txt", "x3.txt", "x4.txt", "x1.txt"] {
      list.mouseDown(
        with: NSEvent.mouseEvent(
          with: .leftMouseDown, location: spot, modifierFlags: [], timestamp: 0,
          windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1)!)
      staged.append(expected)
      pumpMain(
        until: {
          scm.control.operations.isEmpty && scm.changes.staged.count == staged.count
            && list.rowCount == scm.layout.items.count
        }, timeout: 20, "\(expected) を押した後のステージと列の読み直し")
      XCTAssertEqual(Set(scm.changes.staged.map(\.path)), Set(staged), "押した位置の行がステージされる")
    }
  }
}

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

  /// 「ステージされている変更」の唯一の行の − を同じ位置で続けて押すと、1 回目で解除され、区分が消えてポインタの下に来た
  /// 「変更」の同じファイルの ＋ は働かない（続けて押すつもりの押下で、解除したものをステージし直さない）。ポインタを枠の外へ
  /// 動かせば、普通に押せる。押下はアプリの配送の口から送り、窓の段の守りも本物と同じく通す。
  func testPressingOnAfterTheLastStagedRowDoesNotStageWhatCameUnderThePointer() throws {
    let repo = try TempGitRepo()
    try repo.write("x1.txt", "x\n")
    try repo.write("x2.txt", "x\n")
    XCTAssertTrue(repo.git(["add", "x1.txt"]).isSuccess)
    let hosted = host(repo)
    hosted.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    hosted.window.orderFront(nil)
    let scm = hosted.scm
    pumpMain(until: { scm.changes.staged.count == 1 && scm.changes.changes.count == 1 }, "両方の区分")
    let staged = try row(hosted, .staged, "x1.txt")
    pumpMain(until: { self.slot(staged, in: hosted.pane) != nil }, timeout: 3, "載っている列に行")
    let slot = try XCTUnwrap(slot(staged, in: hosted.pane))
    let list = try XCTUnwrap(slot.superview as? RowListView<ScmListSource>)
    let minus = try XCTUnwrap(slot.buttonRects().first { $0.0.control == .unstage }?.1)
    let spot = slot.convert(NSPoint(x: minus.midX, y: minus.midY), to: nil)
    func press() {
      NSApp.sendEvent(.mouse(.leftMouseDown, at: spot, in: hosted.window))
    }

    press()
    pumpMain(
      until: {
        scm.control.operations.isEmpty && scm.changes.staged.isEmpty
          && list.rowCount == scm.layout.items.count
      }, timeout: 20, "解除して列を読み直す")
    let came = try XCTUnwrap(self.slot(try row(hosted, .changes, "x1.txt"), in: hosted.pane))
    let plus = try XCTUnwrap(came.buttonRects().first { $0.0.control == .stage }?.1)
    XCTAssertTrue(
      came.convert(plus, to: nil).contains(spot), "前提: 来た「変更」の x1.txt の ＋ がポインタの下")
    press()
    XCTAssertTrue(scm.control.operations.isEmpty, "来た ＋ は働かない")

    NSApp.sendEvent(.mouse(.mouseMoved, at: NSPoint(x: spot.x - 40, y: spot.y), in: hosted.window))
    press()
    pumpMain(
      until: { scm.control.operations.isEmpty && scm.changes.staged.count == 1 }, timeout: 20,
      "枠の外へ動いた後は普通にステージできる")
  }
}

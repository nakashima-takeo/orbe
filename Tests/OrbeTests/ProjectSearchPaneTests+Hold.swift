import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 結果の列で ↓ を押し続けると、押している間は窓が閉じても開かず、列でキーを離して窓が閉じたら最後の一致だけが開き、焦点は
/// 列のまま。押している間（か離した直後、窓が閉じる前）に、人が結果の外——本文——を押したら、待っていた一致は開かない。
/// 本文は押す前の文書のまま、焦点も押した先のまま。
///
/// 窓の時計は手で進める——押下の座標を測る・描くのに掛かる時間は機械で変わり、遅い機械では本物の時計の窓が押す前に閉じて
/// しまう（「離した直後」を作れない）。押した後に窓を閉じて、待ちが捨てられていることを見る。
///
/// 壊れると何が起きるか。押し続けても離しても最後の一致が開かない、遅れて開いた一致が焦点を本文へ奪う。↓ でたどった直後に
/// 本文を押すと、押した文書が待っていた一致に入れ替わる。
extension ProjectSearchPaneTests {
  struct Held {
    let hosted: Hosted
    /// キーの開きの窓を閉じる（離してから窓の長さが過ぎた）。
    let closeWindow: () -> Void
  }

  /// a.txt・b.txt に一致。結果の列で ↓ を押し続け、b.txt の一致を待たせた状態で返す（`released` なら離して、窓が閉じる前）。
  private func holding(released: Bool) throws -> Held {
    let hosted = try host(["a.txt": "needle\n", "b.txt": "needle\n"])
    searchAll(hosted, "needle")
    let list = try list(hosted)
    hosted.window.makeFirstResponder(list)
    var window: (() -> Void)?
    hosted.search.navigation.delay.schedule = { _, fire in window = fire }
    let arrow = String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)
    hosted.search.select(RowID(path: "a.txt", match: nil))
    list.keyDown(with: .key(arrow, []))
    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("a.txt"), "前提: 押し始めは開く")
    window?()  // リピートが始まるまでの初期遅延
    list.keyDown(with: .key(arrow, [], isRepeat: true))
    list.keyDown(with: .key(arrow, [], isRepeat: true))
    XCTAssertEqual(hosted.search.selection, RowID(path: "b.txt", match: 0), "前提: b.txt を待っている")
    if released { list.keyUp(with: .keyRelease(arrow)) }
    hosted.pane.layoutSubtreeIfNeeded()
    return Held(hosted: hosted, closeWindow: { window?() })
  }

  /// 押したものが見え、窓が閉じても待っていた一致に入れ替わらず、焦点も動かない。
  private func assertTheWaitingMatchStaysClosed(
    _ held: Held, shows url: URL, _ message: String, line: UInt = #line
  ) {
    let hosted = held.hosted
    pumpMain(until: { hosted.pane.document?.url == url }, "\(message): 押したものが見える", line: line)
    let responder = hosted.window.firstResponder
    held.closeWindow()
    hosted.search.navigation.keyDidRelease()
    held.closeWindow()
    XCTAssertEqual(
      hosted.pane.document?.url, url, "\(message): 待っていた一致に入れ替わらない", line: line)
    XCTAssertTrue(hosted.window.firstResponder === responder, "\(message): 焦点は動かない", line: line)
    XCTAssertFalse(
      hosted.tab.group.editor.documents.contains { $0.url == hosted.repo.url("b.txt") },
      "\(message): 待っていた一致は開かない", line: line)
  }

  /// リピートの間隔が窓より長くても（macOS の既定 約 90ms）押している間は開かず、列で離して窓が閉じたら最後の一致を開く。
  func testReleasingAfterHoldingDownOpensOnlyTheLastMatch() throws {
    let held = try holding(released: false)
    let hosted = held.hosted
    let list = try list(hosted)
    held.closeWindow()  // 次のリピートまでに窓が閉じる
    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("a.txt"), "押している間は開かない")

    list.keyUp(with: .keyRelease(String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)))
    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("a.txt"), "離してすぐには開かない")
    held.closeWindow()
    XCTAssertEqual(
      hosted.pane.document?.url, hosted.repo.url("b.txt"),
      "離して窓が閉じたら、その場で最後の選択を開く。これが待たずに成り立たなくなれば、"
        + "testPressingAFileTabWhileHoldingDownDropsTheWaitingOpen と "
        + "testClosingATabWhileHoldingDownDropsTheWaitingOpen の確かめる時点も成り立たない")
    XCTAssertTrue(hosted.window.firstResponder === list, "遅れて開いても焦点は列のまま")
  }

  func testPressingTheBodyWhileHoldingDownDropsTheWaitingOpen() throws {
    for released in [false, true] {
      let held = try holding(released: released)
      let hosted = held.hosted
      placeOffscreen(hosted.window)
      let body = hosted.pane.bodyRect
      try click(hosted.pane, at: NSPoint(x: body.midX, y: body.midY))
      assertTheWaitingMatchStaysClosed(
        held, shows: hosted.repo.url("a.txt"), released ? "離した直後に本文" : "押したまま本文")
    }
  }
}

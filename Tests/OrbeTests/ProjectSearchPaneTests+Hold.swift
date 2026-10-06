import AppKit
import XCTest

@testable import Orbe

/// 結果の列で ↓ を押し続けると、押している間は窓が閉じても開かず、列でキーを離して窓が閉じたら最後の一致だけが開き、焦点は
/// 列のまま。押している間（か離した直後、窓が閉じる前）に、人が結果の外——ファイルタブ・タブの ×——を押したら、待っていた
/// 一致は開かない。押したものが見え、焦点も押した先のまま。
///
/// 窓の時計は手で進める——押下の座標を測る・描くのに掛かる時間は機械で変わり、遅い機械では本物の時計の窓が押す前に閉じて
/// しまう（「離した直後」を作れない）。押した後に窓を閉じて、待ちが捨てられていることを見る。
///
/// 壊れると何が起きるか。押し続けても離しても最後の一致が開かない、遅れて開いた一致が焦点を本文へ奪う。↓ でたどった直後に
/// タブを押すと、押したファイルが一瞬見えた後で待っていた一致に入れ替わり、焦点もその本文へ奪われる。
extension ProjectSearchPaneTests {
  struct Held {
    let hosted: Hosted
    /// キーの開きの窓を閉じる（離してから窓の長さが過ぎた）。
    let closeWindow: () -> Void
  }

  /// a.txt・b.txt に一致、z.txt・x.txt は一致なしで普通のタブで開いておく。窓は物理画面の外へ並べる（`sendEvent` は
  /// ordered-in の窓にしか配送しない）。結果の列で ↓ を押し続け、b.txt の一致を待たせた状態で返す（`released` なら離して、
  /// 窓が閉じる前）。
  private func holding(released: Bool) throws -> Held {
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
    var window: (() -> Void)?
    hosted.search.navigationDelay.schedule = { _, fire in window = fire }
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
    _ = try probe(hosted.pane) { _ in hosted.pane.shell.tabs.count == 3 }
    return Held(hosted: hosted, closeWindow: { window?() })
  }

  /// ファイルタブ `name` の名前の上（面の座標）。
  private func tabPoint(_ hosted: Hosted, _ name: String) throws -> NSPoint {
    let index = try XCTUnwrap(hosted.pane.shell.tabs.firstIndex { $0.name == name })
    let slot = fileTabSlotCenter(hosted.pane, index)
    return NSPoint(x: slot.x - 30, y: slot.y)
  }

  /// 押したものが見え、窓が閉じても待っていた一致に入れ替わらず、焦点も動かない。
  private func assertTheWaitingMatchStaysClosed(
    _ held: Held, shows url: URL, _ message: String, line: UInt = #line
  ) {
    let hosted = held.hosted
    pumpMain(until: { hosted.pane.document?.url == url }, "\(message): 押したものが見える", line: line)
    let responder = hosted.window.firstResponder
    held.closeWindow()
    hosted.search.navigationKeyDidRelease()
    held.closeWindow()
    RunLoop.main.run(until: Date())
    XCTAssertEqual(
      hosted.pane.document?.url, url, "\(message): 待っていた一致に入れ替わらない", line: line)
    XCTAssertTrue(hosted.window.firstResponder === responder, "\(message): 焦点は動かない", line: line)
    XCTAssertFalse(
      hosted.tab.editor.documents.contains { $0.url == hosted.repo.url("b.txt") },
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
    XCTAssertEqual(hosted.pane.document?.url, hosted.repo.url("b.txt"), "離して窓が閉じたら最後の選択を開く")
    XCTAssertTrue(hosted.window.firstResponder === list, "遅れて開いても焦点は列のまま")
  }

  func testPressingAFileTabWhileHoldingDownDropsTheWaitingOpen() throws {
    for released in [false, true] {
      let held = try holding(released: released)
      try click(held.hosted.pane, at: tabPoint(held.hosted, "z.txt"))
      assertTheWaitingMatchStaysClosed(
        held, shows: held.hosted.repo.url("z.txt"), released ? "離した直後にタブ" : "押したままタブ")
    }
  }

  func testClosingATabWhileHoldingDownDropsTheWaitingOpen() throws {
    for released in [false, true] {
      let held = try holding(released: released)
      let hosted = held.hosted
      let x = hosted.repo.url("x.txt")
      let index = try XCTUnwrap(hosted.pane.shell.tabs.firstIndex { $0.id == x })
      try click(hosted.pane, at: fileTabSlotCenter(hosted.pane, index))
      pumpMain(until: { !hosted.tab.editor.documents.contains { $0.url == x } }, "× で閉じる")
      assertTheWaitingMatchStaysClosed(
        held, shows: hosted.repo.url("a.txt"), released ? "離した直後に ×" : "押したまま ×")
    }
  }
}

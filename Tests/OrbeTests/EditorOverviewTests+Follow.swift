import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 俯瞰が文書の出来事に追従する——スクロール・キャレット・ハンク・本文のどれが変わっても描き直しを求め、印は編集と
/// index（baseline）に付いてくる。削除の境は俯瞰に出ない。帯のドラッグは効かない。
///
/// 壊れると何が起きるか。スクロールしても帯が止まったままで、次に何かが描き直すまで「どこを見ているか」が嘘になる。
/// 行を足しても印が出ず、`git add` しても印が残る。
extension EditorOverviewTests {
  private var barX: CGFloat { 1 + 100 + overview.marksBarX + 2 }
  private var edgeX: CGFloat { 1 + overview.minimapMarkX + 1 }

  /// 描き終えた俯瞰が、次の出来事で描き直しを求める（`alpha` は毎回描くので、求めたかは描き直しの要求で見る）。
  func testTheOverviewAsksToRedrawWhenTheViewportCaretHunksOrTextChange() throws {
    let hosted = try host(lines(200))
    let view = hosted.pane.overview
    let document = hosted.document
    // layer を持つ view の「描き直せ」は layer に立つ。
    func asksToRedraw() -> Bool { view.needsDisplay || view.layer?.needsDisplay() == true }
    func settle() {
      view.displayIfNeeded()
      XCTAssertFalse(asksToRedraw(), "描き終えている")
    }

    settle()
    hosted.scroll.contentView.scroll(to: NSPoint(x: 0, y: style.lineHeight * 30))
    hosted.scroll.reflectScrolledClipView(hosted.scroll.contentView)
    pumpMain(until: { document.surface.viewport.firstVisible > 0 }, "スクロールが届く")
    XCTAssertTrue(asksToRedraw(), "スクロール")

    settle()
    document.surface.selectedRange = NSRange(
      location: document.lineIndex.start(ofRow: 40), length: 0)
    XCTAssertTrue(asksToRedraw(), "キャレット")

    settle()
    document.baseline = lines(199)
    pumpMain(until: { !document.hunks.isEmpty }, "ハンク")
    XCTAssertTrue(asksToRedraw(), "ハンク")

    settle()
    hosted.window.makeFirstResponder(document.surface.responder)
    document.surface.responder.keyDown(with: .key("x", []))
    XCTAssertTrue(asksToRedraw(), "本文")
  }

  /// 印は編集に追従し（打った行に変更の印）、baseline が本文に追いつけば（`git add`）消える。
  func testMarksFollowEditsAndDisappearWhenTheBaselineCatchesUp() throws {
    let hosted = try host(lines(20))
    let view = hosted.pane.overview
    let document = hosted.document
    let scale = rowScale(hosted)
    document.baseline = lines(20)
    XCTAssertEqual(try alpha(view, barX, 5 * scale + 1), 0, "差が無ければ印は無い")

    hosted.window.makeFirstResponder(document.surface.responder)
    document.surface.selectedRange = NSRange(
      location: document.lineIndex.start(ofRow: 5), length: 0)
    document.surface.responder.keyDown(with: .key("x", []))
    pumpMain(until: { document.hunks.count == 1 }, "ハンクが作り直される")
    XCTAssertTrue(isBlue(try color(view, barX, 5 * scale + 1)), "打った行に変更の印")
    XCTAssertTrue(try alpha(view, edgeX, rowY(5)) > 100, "ミニマップの左端にも")

    document.baseline = document.surface.text
    pumpMain(until: { document.hunks.isEmpty }, "index が追いつく")
    XCTAssertEqual(try alpha(view, barX, 5 * scale + 1), 0, "印の列から消える")
    XCTAssertTrue(try alpha(view, edgeX, rowY(5)) < 40, "左端からも消える（帯だけが残る）")
  }

  /// 削除の境（ガターの三角）は俯瞰に出ない——消えた行の上下の行は印を持たない。
  func testADeletionLeavesNoMarkInTheOverview() throws {
    let hosted = try host(lines(20))
    let view = hosted.pane.overview
    let scale = rowScale(hosted)
    hosted.document.baseline = lines(20).replacingOccurrences(
      of: "line 10\n", with: "line 10\ngone\n")
    pumpMain(until: { hosted.document.hunks.count == 1 }, "ハンク")
    XCTAssertEqual(hosted.document.hunks.first?.newCount, 0, "削除のハンク")
    for line in [9, 10] {
      XCTAssertEqual(try alpha(view, barX, CGFloat(line) * scale + 1), 0, "印の列 行 \(line + 1)")
      XCTAssertTrue(try alpha(view, edgeX, rowY(line)) < 40, "ミニマップの左端 行 \(line + 1)")
    }
  }

  /// 帯を押したまま動かしても、押した位置の行が中央に来たままで付いてこない（ドラッグは効かない）。
  func testDraggingOnTheMinimapDoesNotScroll() throws {
    let hosted = try host(lines(1000))
    let view = hosted.pane.overview
    let document = hosted.document
    func mouse(_ type: NSEvent.EventType, line: Int) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type, location: view.convert(NSPoint(x: 50, y: rowY(line)), to: nil),
          modifierFlags: [], timestamp: 0, windowNumber: hosted.window.windowNumber, context: nil,
          eventNumber: 0, clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try mouse(.leftMouseDown, line: 60))
    pumpMain(until: { document.surface.viewport.firstVisible > 0 }, "押した行へ")
    let landed = document.surface.viewport

    view.mouseDragged(with: try mouse(.leftMouseDragged, line: 20))
    view.mouseUp(with: try mouse(.leftMouseUp, line: 20))
    XCTAssertEqual(document.surface.viewport, landed)
  }
}

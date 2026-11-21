import AppKit
import XCTest

@testable import Orbe

/// 連の器（`GroupFacesView`）が開閉を 2 層の見え方へ写す規則——両面は常に器いっぱい・端末の寸法は器だけに従う・
/// 開いている間は端末面を隠す（描画は続ける）・描くのは見せている端末だけ・動きの途中は両面を見せる・クリックの届き先は開閉に従う。
///
/// 壊れると何が起きるか。端末の寸法が開閉や連の中の切替で変わると、そのたびに pty が resize され scrollback が折り返し直される。
/// 開いている間に端末面が隠れないと、半透明のエディター面の下の端末の文字が透ける。覆われている端末の描画が止まると、見せ直した
/// 最初のフレームに古い出力か何も描かれていない状態が出る。見せていない兄弟や隠れた器の端末が描き続けると、見えない描画の負荷がかかる。
/// 置き換えられた動きの完了で「途中」が解けると、閉じる途中にエディター面が消え、開く途中に下が抜ける。
/// 閉じる途中のエディター面がクリックを取ると、隠れる view に first responder が残る。
final class GroupFacesViewTests: OrbeTestCase {
  private let size = NSSize(width: 1000, height: 400)

  private func laidOut(open: Bool = false) -> TerminalTab {
    let tab = TerminalTab.alone(cwd: "/tmp")
    tab.group.view.setEditorOpen(open, animated: false)
    tab.group.view.frame = NSRect(origin: .zero, size: size)
    tab.group.view.layoutSubtreeIfNeeded()
    return tab
  }

  /// 器を窓に載せ、動きを減らす設定を切る（動きつきの開閉が即時に落ちないように）。
  private func hosted(_ tab: TerminalTab) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = tab.group.view
    tab.group.view.reduceMotion = false
    tab.group.view.layoutSubtreeIfNeeded()
    return window
  }

  private func rect(of view: NSView, in container: NSView) -> NSRect {
    view.convert(view.bounds, to: container)
  }

  // MARK: - 重なり

  /// 器は閉じて生まれる。エディター面は隠れ、端末が器いっぱい。
  func testClosedShowsTheTerminalAcrossTheWholeContainer() {
    let tab = laidOut()
    let view = tab.group.view

    XCTAssertTrue(view.editor.isHiddenOrHasHiddenAncestor, "閉じたエディター面は隠れる（根のサービスを離す）")
    XCTAssertFalse(tab.terminal.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(rect(of: tab.terminal, in: view), NSRect(origin: .zero, size: size))
    XCTAssertEqual(tab.surface.bounds.size, size)
  }

  /// 開くとエディター面が器いっぱいに重なり、下の端末面は隠れるが、端末は描き続け、寸法は器のまま。
  func testOpenCoversTheContainerAndHidesTheTerminalWithoutResizingIt() {
    let tab = laidOut(open: true)
    let view = tab.group.view

    XCTAssertFalse(view.editor.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(try XCTUnwrap(view.editor.superview).alphaValue, 1)
    XCTAssertEqual(rect(of: view.editor, in: view), NSRect(origin: .zero, size: size))
    XCTAssertTrue(tab.terminal.isHiddenOrHasHiddenAncestor, "開いている間は下の端末を見せない")
    XCTAssertTrue(tab.surface.wantsRendering, "覆われても描き続ける")
    XCTAssertEqual(tab.surface.bounds.size, size, "覆われても寸法は器のまま")
  }

  // MARK: - 端末を描くか

  /// 描くのは見せている 1 枚だけ。見せる端末を替えると、覆われたままでも新しい端末が描き、元の端末は止まる。
  func testOnlyTheShownTerminalRendersEvenWhileCovered() {
    let tab = laidOut(open: true)
    let sibling = TerminalTab(cwd: "/tmp", group: tab.group)
    let view = tab.group.view

    view.add(terminal: sibling.terminal)
    XCTAssertTrue(tab.surface.wantsRendering)
    XCTAssertFalse(sibling.surface.wantsRendering, "差しただけの兄弟は描かない")

    view.show(terminal: sibling.terminal)
    XCTAssertTrue(sibling.surface.wantsRendering, "覆われたまま見せ始めた端末が描く")
    XCTAssertFalse(tab.surface.wantsRendering, "見せなくなった端末は止まる")
  }

  /// 器が隠れれば（器自身でも祖先でも）見せている端末も止まり、現れれば描き直す。窓に付いていない器でも同じ。
  func testHidingTheContainerOrAnAncestorStopsRendering() {
    let tab = laidOut(open: true)
    let view = tab.group.view
    let parent = NSView()
    parent.addSubview(view)

    view.isHidden = true
    XCTAssertFalse(tab.surface.wantsRendering, "器が隠れると止まる")
    view.isHidden = false
    XCTAssertTrue(tab.surface.wantsRendering)

    parent.isHidden = true
    XCTAssertFalse(tab.surface.wantsRendering, "祖先が隠れても止まる")
    parent.isHidden = false
    XCTAssertTrue(tab.surface.wantsRendering)
  }

  /// 外した端末は描かない。別の器へ移った端末は、元の器から外しても描いたまま。
  func testRemovingStopsRenderingUnlessTheTerminalMovedAway() {
    let tab = laidOut()
    let view = tab.group.view

    view.remove(terminal: tab.terminal)
    XCTAssertFalse(tab.surface.wantsRendering, "外した端末は描かない")

    let moving = TerminalTab(cwd: "/tmp", group: tab.group)
    let destination = TerminalTab.alone(cwd: "/tmp").group.view
    view.add(terminal: moving.terminal)
    view.show(terminal: moving.terminal)
    destination.add(terminal: moving.terminal)
    destination.show(terminal: moving.terminal)
    view.remove(terminal: moving.terminal)
    XCTAssertTrue(moving.surface.wantsRendering, "移り先で見せている端末には触れない")
  }

  // MARK: - 端末の寸法

  /// 連の兄弟の端末は見せていなくても器の寸法を持ち（差した瞬間から・器の resize でも）、見せる端末を替えても寸法は
  /// 変わらない——連の中の切替で pty の resize と再折り返しが起きない。
  func testSiblingTerminalsShareTheContainerSizeAndShowingDoesNotResize() {
    let tab = laidOut()
    let sibling = TerminalTab(cwd: "/tmp", group: tab.group)
    let view = tab.group.view

    view.add(terminal: sibling.terminal)
    XCTAssertTrue(sibling.terminal.isHidden, "差した端末は隠れている")
    XCTAssertTrue(view.shownTerminal === tab.terminal)
    XCTAssertEqual(sibling.surface.bounds.size, size, "差した瞬間から器の寸法")

    view.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(sibling.surface.bounds.size, NSSize(width: 1200, height: 600), "隠れた兄弟も器に従う")

    view.show(terminal: sibling.terminal)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(tab.terminal.isHidden)
    XCTAssertFalse(sibling.terminal.isHidden)
    XCTAssertEqual(sibling.surface.bounds.size, NSSize(width: 1200, height: 600))
    XCTAssertEqual(tab.surface.bounds.size, NSSize(width: 1200, height: 600))
  }

  // MARK: - 開閉の動き

  /// 動きを減らす設定では、窓の中でも開き終わりの見え方へ即時に切り替わる。
  func testReduceMotionMakesTheChangeImmediate() {
    let tab = laidOut()
    let window = hosted(tab)
    defer { window.contentView = nil }
    tab.group.view.reduceMotion = true

    tab.group.view.setEditorOpen(true, animated: true)
    XCTAssertTrue(tab.terminal.isHiddenOrHasHiddenAncestor, "開き終わりの見え方")
  }

  /// 動きの途中は両面を見せ、開閉と濃さの行き先は押した瞬間に切り替わる。途中で反転しても、置き換えられた動きの完了では
  /// 「途中」が解けず、最後の動きが終わったときに解けて行き先の見え方になる。
  func testFadeKeepsBothFacesUntilTheLastStartedFadeEnds() {
    let tab = laidOut()
    let window = hosted(tab)
    defer { window.contentView = nil }
    let view = tab.group.view

    view.setEditorOpen(true, animated: true)
    XCTAssertFalse(view.editor.isHiddenOrHasHiddenAncestor)
    XCTAssertFalse(tab.terminal.isHiddenOrHasHiddenAncestor, "開く途中は下の端末を見せる")
    XCTAssertEqual(try XCTUnwrap(view.editor.superview).alphaValue, 1, "濃さの行き先")

    view.setEditorOpen(false, animated: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    XCTAssertFalse(
      view.editor.isHiddenOrHasHiddenAncestor, "置き換えられた動きの完了では解けず、閉じる途中のエディター面は見えている")
    XCTAssertEqual(try XCTUnwrap(view.editor.superview).alphaValue, 0)

    pumpMain(until: { view.editor.isHiddenOrHasHiddenAncestor }, timeout: 2, "最後の動きが終わって隠れる")
    XCTAssertFalse(tab.terminal.isHiddenOrHasHiddenAncestor)
  }

  /// 同じ値は何もしない——照合が同じ開閉を渡しても、進行中の動きを切らない。
  func testSameValueKeepsTheFadeRunning() {
    let tab = laidOut()
    let window = hosted(tab)
    defer { window.contentView = nil }
    let view = tab.group.view

    view.setEditorOpen(true, animated: true)
    view.setEditorOpen(true, animated: false)
    XCTAssertFalse(tab.terminal.isHiddenOrHasHiddenAncestor, "開く途中のまま下の端末が見えている")
  }

  /// 即時の切り替えは進行中の動きを打ち切り、その場で行き先の見え方になる。
  func testImmediateChangeCutsTheFade() {
    let tab = laidOut()
    let window = hosted(tab)
    defer { window.contentView = nil }
    let view = tab.group.view

    view.setEditorOpen(true, animated: true)
    view.setEditorOpen(false, animated: false)
    XCTAssertTrue(view.editor.isHiddenOrHasHiddenAncestor)
  }

  // MARK: - クリックの届き先

  /// 閉じる途中のエディター面はまだ見えているが、クリックは下の端末へ届く。開いている間はエディターへ届く。
  func testClicksFollowTheOpenStateDuringTheFade() throws {
    let tab = laidOut(open: true)
    let window = hosted(tab)
    defer { window.contentView = nil }
    let view = tab.group.view
    let point = NSPoint(x: 500, y: 200)

    let open = try XCTUnwrap(view.hitTest(point))
    XCTAssertTrue(open.isDescendant(of: view.editor), "開いている間はエディター: \(open)")

    view.setEditorOpen(false, animated: true)
    XCTAssertFalse(view.editor.isHiddenOrHasHiddenAncestor, "前提: 閉じる途中でエディター面が見えている")
    let closing = try XCTUnwrap(view.hitTest(point))
    XCTAssertTrue(closing.isDescendant(of: tab.terminal), "閉じる途中は端末: \(closing)")
  }
}

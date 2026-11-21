import AppKit
import XCTest

@testable import Orbe

/// 連の器（`GroupFacesView`）が開閉を 2 層の見え方へ写す規則——両面は常に器いっぱい・端末の寸法は開閉に触れない・
/// 開いている間は端末面を隠す・動きの途中は両面を見せる・クリックの届き先は開閉に従う。
///
/// 壊れると何が起きるか。端末の寸法が開閉で変わると、⌘E のたびに pty が resize され scrollback が折り返し直される。
/// 覆われた端末が窓の resize に追従しないと、閉じた瞬間に resize が起き、透かしたときの端末が古い大きさで見える。
/// 開いている間に端末面が隠れないと、半透明のエディター面の下で端末が描かれ続け、文字が透ける。
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

    XCTAssertFalse(view.isEditorOpen)
    XCTAssertTrue(view.editor.isHiddenOrHasHiddenAncestor, "閉じたエディター面は隠れる（根のサービスを離す）")
    XCTAssertFalse(tab.terminal.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(rect(of: tab.terminal, in: view), NSRect(origin: .zero, size: size))
    XCTAssertEqual(tab.surface.bounds.size, size)
  }

  /// 開くとエディター面が器いっぱいに重なり、下の端末面は隠れる（描かない）が、端末の寸法は器のまま。
  func testOpenCoversTheContainerAndHidesTheTerminalWithoutResizingIt() {
    let tab = laidOut(open: true)
    let view = tab.group.view

    XCTAssertFalse(view.editor.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(try XCTUnwrap(view.editor.superview).alphaValue, 1)
    XCTAssertEqual(rect(of: view.editor, in: view), NSRect(origin: .zero, size: size))
    XCTAssertTrue(tab.terminal.isHiddenOrHasHiddenAncestor, "開いている間は下の端末を描かない")
    XCTAssertEqual(tab.surface.bounds.size, size, "覆われても寸法は器のまま")
  }

  // MARK: - 端末の寸法

  /// 開閉で端末の寸法は変わらず、開いている間の器の resize には覆われた端末も追従する。
  func testTerminalSizeFollowsOnlyTheContainer() {
    let tab = laidOut()
    let view = tab.group.view

    view.setEditorOpen(true, animated: false)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(tab.surface.bounds.size, size, "開いても変わらない")

    view.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      tab.surface.bounds.size, NSSize(width: 1200, height: 600), "覆われている間も器の resize に追従する")

    view.setEditorOpen(false, animated: false)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(tab.surface.bounds.size, NSSize(width: 1200, height: 600), "閉じても変わらない")
  }

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

  /// 窓に無い器は、動きつきを渡されても即時に切り替わる。
  func testAnimatedChangeOutsideAWindowIsImmediate() {
    let tab = laidOut()
    let view = tab.group.view
    view.reduceMotion = false

    view.setEditorOpen(true, animated: true)
    XCTAssertFalse(view.isFading)
    XCTAssertTrue(tab.terminal.isHiddenOrHasHiddenAncestor)
  }

  /// 動きを減らす設定では、窓の中でも即時に切り替わる。
  func testReduceMotionMakesTheChangeImmediate() {
    let tab = laidOut()
    let window = hosted(tab)
    defer { window.contentView = nil }
    tab.group.view.reduceMotion = true

    tab.group.view.setEditorOpen(true, animated: true)
    XCTAssertFalse(tab.group.view.isFading)
  }

  /// 動きの途中は両面を見せ、開閉と濃さの行き先は押した瞬間に切り替わる。途中で反転しても、置き換えられた動きの完了では
  /// 「途中」が解けず、最後の動きが終わったときに解けて行き先の見え方になる。
  func testFadeKeepsBothFacesUntilTheLastStartedFadeEnds() {
    let tab = laidOut()
    let window = hosted(tab)
    defer { window.contentView = nil }
    let view = tab.group.view

    view.setEditorOpen(true, animated: true)
    XCTAssertTrue(view.isEditorOpen)
    XCTAssertTrue(view.isFading)
    XCTAssertFalse(view.editor.isHiddenOrHasHiddenAncestor)
    XCTAssertFalse(tab.terminal.isHiddenOrHasHiddenAncestor, "開く途中は下の端末を見せる")
    XCTAssertEqual(try XCTUnwrap(view.editor.superview).alphaValue, 1, "濃さの行き先")

    view.setEditorOpen(false, animated: true)
    XCTAssertFalse(view.isEditorOpen)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    XCTAssertTrue(view.isFading, "置き換えられた動きの完了では解けない")
    XCTAssertFalse(view.editor.isHiddenOrHasHiddenAncestor, "閉じる途中のエディター面は見えている")
    XCTAssertEqual(try XCTUnwrap(view.editor.superview).alphaValue, 0)

    pumpMain(until: { !view.isFading }, timeout: 2, "最後の動きが終わる")
    XCTAssertTrue(view.editor.isHiddenOrHasHiddenAncestor)
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
    XCTAssertTrue(view.isFading)
  }

  /// 即時の切り替えは進行中の動きを打ち切り、動きの完了の知らせでは何も変わらない。
  func testImmediateChangeCutsTheFade() {
    let tab = laidOut()
    let window = hosted(tab)
    defer { window.contentView = nil }
    let view = tab.group.view

    view.setEditorOpen(true, animated: true)
    view.setEditorOpen(false, animated: false)
    XCTAssertFalse(view.isFading)
    XCTAssertTrue(view.editor.isHiddenOrHasHiddenAncestor)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertFalse(view.isFading)
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
    XCTAssertTrue(view.isFading, "前提: 閉じる途中")
    let closing = try XCTUnwrap(view.hitTest(point))
    XCTAssertTrue(closing.isDescendant(of: tab.terminal), "閉じる途中は端末: \(closing)")
  }
}

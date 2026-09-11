import AppKit
import XCTest

@testable import Orbe

/// タブの器（`TabFacesView`）が配置を子の frame へ写す規則——面の並び・隠れた面・端末の寸法の据え置き・
/// 投影の差分通知・焦点の面の responder。窓に載せず、タブを直接組んで器の幅だけを与える。
///
/// 壊れると何が起きるか。面の並びや錨がずれると端末の中身が背の下へ潜る、または面の外へはみ出す。
/// 隠れた面が isHidden にならないと libghostty の占有同期が「見えている」と誤り描画を続ける。
/// 隠れた端末の寸法が据え置かれないと ⌘E のたびに pty が resize され scrollback が折り返し直される。
/// 投影の通知が差分ゲートを失うとライブリサイズの毎フレームで全 workspace の chrome snapshot が組まれる。
/// 焦点の面が幅で変わると、記憶した焦点と responder の行き先がずれる。
final class TabFacesViewTests: OrbeTestCase {
  /// 背 14 を除いた内容幅が 1000、焦点帯 2 を除いた中身の高さが 398 になる器。
  private let size = NSSize(width: 1014, height: 400)

  private func laidOut(_ faces: FaceLayout, size: NSSize? = nil) -> TerminalTab {
    let tab = TerminalTab(cwd: "/tmp")
    tab.setFaces(faces, animated: false)
    tab.view.frame = NSRect(origin: .zero, size: size ?? self.size)
    tab.view.layoutSubtreeIfNeeded()
    return tab
  }

  /// 器の座標で見た中身の矩形。
  private func rect(of view: NSView, in container: NSView) -> NSRect {
    view.convert(view.bounds, to: container)
  }

  // MARK: - 面の並び

  /// 左からエディター面・背・端末面。中身は面いっぱいの幅で、上辺の焦点帯 2px の下に置かれる。
  func testLayoutPlacesEditorSpineAndTerminalLeftToRight() {
    let tab = laidOut(FaceLayout(editorRatio: 0.25, focus: .terminal))
    let view = tab.view

    XCTAssertEqual(rect(of: view.editor, in: view), NSRect(x: 0, y: 2, width: 250, height: 398))
    XCTAssertEqual(view.spine.frame, NSRect(x: 250, y: 0, width: 14, height: 400))
    XCTAssertEqual(
      rect(of: view.terminal, in: view), NSRect(x: 264, y: 2, width: 750, height: 398))
    XCTAssertEqual(tab.surface.bounds.size, NSSize(width: 750, height: 398), "端末の中身も面と同じ寸法")
  }

  /// 端末だけの配置ではエディター面は隠れ、端末が背の右を全部使う。
  func testTerminalOnlyHidesTheEditorFace() {
    let tab = laidOut(.terminalOnly)
    let view = tab.view

    XCTAssertTrue(view.editor.isHiddenOrHasHiddenAncestor, "幅 0 の面は隠れる（占有同期に乗る）")
    XCTAssertFalse(view.terminal.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(view.spine.frame.minX, 0)
    XCTAssertEqual(rect(of: view.terminal, in: view), NSRect(x: 14, y: 2, width: 1000, height: 398))
  }

  /// エディター全面では端末面が隠れ、エディターが背の左を全部使う。
  func testEditorOnlyHidesTheTerminalFace() {
    let tab = laidOut(FaceLayout(editorRatio: 1, focus: .editor))
    let view = tab.view

    XCTAssertTrue(view.terminal.isHiddenOrHasHiddenAncestor)
    XCTAssertFalse(view.editor.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(view.spine.frame.minX, 1000)
    XCTAssertEqual(rect(of: view.editor, in: view), NSRect(x: 0, y: 2, width: 1000, height: 398))
  }

  // MARK: - 隠れた端末の寸法

  /// 端末が隠れている間は器の幅が変わっても端末の寸法を変えず、戻したときに今の幅で置き直す。
  /// 配置を変えるたびに layout を通すのは、窓の display サイクルが端末面の寸法を surface へ配るのと同じ手順。
  func testHiddenTerminalKeepsItsLastVisibleSize() {
    let tab = laidOut(FaceLayout(editorRatio: 0.5, focus: .terminal))
    XCTAssertEqual(tab.surface.bounds.width, 500, "前提: 分割で端末が 500 幅")

    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(tab.surface.bounds.size, NSSize(width: 500, height: 398), "隠した瞬間に縮めない")

    tab.view.frame = NSRect(x: 0, y: 0, width: 1214, height: 600)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      tab.surface.bounds.size, NSSize(width: 500, height: 398), "隠れている間の器の resize に追従しない")

    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .editor), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      tab.surface.bounds.size, NSSize(width: 600, height: 598), "戻したら今の器の幅で置き直す")
  }

  /// 隠れたまま生まれた端末（エディター全面で復元）は、戻したときに得る幅＝内容幅で起きる。
  func testTerminalBornHiddenWakesAtTheContentWidth() {
    let tab = TerminalTab(
      restoring: TabState(
        cwd: "/tmp", agent: nil, explicitTitle: nil,
        faces: FaceLayout(editorRatio: 1, focus: .editor)), resumeSpawn: { _ in nil })
    tab.view.frame = NSRect(origin: .zero, size: size)
    tab.view.layoutSubtreeIfNeeded()

    XCTAssertTrue(tab.view.terminal.isHiddenOrHasHiddenAncestor, "前提: 端末は隠れて生まれる")
    XCTAssertEqual(tab.surface.bounds.size, NSSize(width: 1000, height: 398))
  }

  // MARK: - 投影の通知

  /// 投影（ドット・背の見え方・分割中か）が変わったときだけ通知し、同じ投影のまま layout が走っても黙る。
  func testProjectionChangeFiresOnlyWhenTheProjectionDiffers() {
    let tab = laidOut(.terminalOnly)
    var fired = 0
    tab.view.onProjectionChange = { fired += 1 }

    tab.view.frame = NSRect(x: 0, y: 0, width: 1214, height: 400)
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(fired, 0, "幅だけ変わっても投影は同じ")

    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    XCTAssertEqual(fired, 1, "分割になれば通知")

    tab.setFaces(FaceLayout(editorRatio: 0.4, focus: .terminal), animated: false)
    XCTAssertEqual(fired, 1, "分割のまま幅が変わっても投影は同じ")

    tab.setFaces(FaceLayout(editorRatio: 0.4, focus: .editor), animated: false)
    XCTAssertEqual(fired, 2, "焦点が移ればドットが変わる")
  }

  // MARK: - 焦点の面

  /// 焦点の面の responder は配置だけで決まり、器の幅（まだ 0 でも）に依らない。
  func testFocusTargetFollowsTheLayoutNotTheWidth() {
    let tab = TerminalTab(cwd: "/tmp")
    XCTAssertTrue(tab.focusTarget === tab.surface, "既定は端末")

    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .editor), animated: false)
    XCTAssertTrue(tab.focusTarget === tab.view.editor, "幅 0 の器でもエディター焦点はエディター pane")

    tab.setFaces(FaceLayout(editorRatio: 0.5, focus: .terminal), animated: false)
    XCTAssertTrue(tab.focusTarget === tab.surface)
  }
}

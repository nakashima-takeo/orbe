import AppKit
import XCTest

@testable import Orbe

/// ファイルタブの右端の枠——VS Code のタブと同じく、アクティブは × を常に、それ以外はタブにポインタがあるときだけ
/// 出し、未保存は × 自体にポインタがあるときのほかは × の代わりに ● を出す。× にポインタを乗せると枠に地が付いて × が明るくなり、
/// 20 四方の枠のどこを押しても閉じる。
///
/// 壊れると何が起きるか。どのタブを閉じられるのか見えない（アクティブにも × が無い）。小さな × を外して隣のタブを
/// 切り替えてしまう。押せる範囲に乗ったかが見えないまま押すことになる。未保存の印と × が並んで幅を食う。
@MainActor
final class EditorPaneViewTabCloseTests: OrbeTestCase {
  private enum SlotLook: Equatable {
    case empty
    case dot
    case close
    case closeHovered
  }

  private struct Row {
    let tab: TerminalTab
    let window: NSWindow
    var pane: EditorPaneView { tab.view.editor }
  }

  /// 幅 900・サイドバー閉の面に 3 枚: 未保存の a・保存済みの b・アクティブの c。窓は物理画面の外へ並べる
  /// （`sendEvent` は ordered-in の窓にしか配送しない）。
  private func row() throws -> Row {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    window.appearance = NSAppearance(named: .darkAqua)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    pane.shell.selectPanel(.files)
    let a = try tab.editor.open(try caseFile("a.swift", "let a = 1\n"))
    a.surface.responder.perform(Selector(("insertText:")), with: "x")
    _ = try tab.editor.open(try caseFile("b.txt", "b"))
    _ = try tab.editor.open(try caseFile("c.md", "c"))
    tab.view.layoutSubtreeIfNeeded()
    pumpMain(
      until: { pane.shell.tabs.map(\.isDirty) == [true, false, false] }, "a だけ未保存・c がアクティブ")
    return Row(tab: tab, window: window)
  }

  private func looks(_ probe: PaneProbe, _ pane: EditorPaneView) throws -> [SlotLook] {
    try pane.shell.tabs.indices.map { index in
      let c = fileTabSlotCenter(pane, index)
      let ground = try probe.rgb(c.x, y: Theme.Layout.editorFileTabs - 2)  // タブの地（枠の下）
      let plate = try probe.rgb(c.x - 8, y: c.y - 7)  // 枠の内側で印から外れた点
      if PaneProbe.same(try probe.rgb(c.x, y: c.y), plate) { return .empty }
      if !PaneProbe.same(try probe.rgb(c.x + 3, y: c.y), plate) { return .dot }  // × の斜線は横 3 を通らない
      return PaneProbe.same(plate, ground) ? .close : .closeHovered
    }
  }

  func testSlotShowsCloseDotOrNothingByActiveDirtyAndPointer() throws {
    let row = try row()
    defer { row.window.orderOut(nil) }
    let pane = row.pane
    let slot = { (index: Int) in self.fileTabSlotCenter(pane, index) }
    let onTab = { (index: Int) in NSPoint(x: slot(index).x - 24, y: slot(index).y) }  // 名前の上
    let away = NSPoint(x: pane.headerHost.frame.maxX - 4, y: slot(0).y)  // タブの無い帯
    let cases: [(pointer: NSPoint, expected: [SlotLook])] = [
      (away, [.dot, .empty, .close]),  // ポインタなし
      (onTab(1), [.dot, .close, .close]),  // 保存済みのタブ b の上
      (onTab(0), [.dot, .empty, .close]),  // 未保存のタブ a の上（● のまま）
      (slot(1), [.dot, .closeHovered, .close]),  // b の × の上
      (slot(0), [.closeHovered, .empty, .close]),  // a の × の上
      (slot(2), [.dot, .empty, .closeHovered]),  // アクティブの c の × の上
    ]
    for (index, step) in cases.enumerated() {
      movePointer(pane, to: step.pointer)
      let drawn = try probe(pane) { try looks($0, pane) == step.expected }
      XCTAssertEqual(try looks(drawn, pane), step.expected, "cases[\(index)]")
    }

    movePointer(pane, to: slot(1))
    let hovered = try probe(pane) { try looks($0, pane)[1] == .closeHovered }
    let brightness = { (p: NSPoint) in try hovered.rgb(p.x, y: p.y).reduce(0, +) }
    XCTAssertGreaterThan(
      try brightness(slot(1)), try brightness(slot(2)) + 60, "乗っている × は乗っていない × より明るい")
  }

  /// 枠は 20 四方——中心から 9 ずれた端を押しても閉じ、枠の外（タブの右の余白）を押せばタブの切替になる。
  func testTheWholeTwentyPointSlotCloses() throws {
    let row = try row()
    defer { row.window.orderOut(nil) }
    let pane = row.pane
    let names = { pane.shell.tabs.map(\.name) }
    // 写しが変わっても描き直す前のタブ行は古い位置のまま押される——押す前に描画が写しに追いつくのを待つ。
    let drawn = { (expected: [SlotLook]) in
      _ = try self.probe(pane) { try self.looks($0, pane) == expected }
    }

    let b = fileTabSlotCenter(pane, 1)
    try click(pane, at: NSPoint(x: b.x + 9, y: b.y))
    pumpMain(until: { names() == ["a.swift", "c.md"] }, "枠の右端を押して b を閉じる")
    XCTAssertEqual(pane.shell.tabs.last?.isActive, true, "閉じてもアクティブは c のまま")

    try drawn([.dot, .close])
    let c = fileTabSlotCenter(pane, 1)
    try click(pane, at: NSPoint(x: c.x, y: c.y + 9))
    pumpMain(until: { names() == ["a.swift"] }, "枠の下端を押して c を閉じる")

    _ = try row.tab.editor.open(try caseFile("d.txt", "d"))
    try drawn([.dot, .close])
    let a = fileTabSlotCenter(pane, 0)
    try click(pane, at: NSPoint(x: a.x + Theme.Layout.editorTabClose / 2 + 2, y: a.y))
    pumpMain(until: { pane.shell.tabs.first?.isActive == true }, "枠の外はタブの切替")
    XCTAssertEqual(names(), ["a.swift", "d.txt"], "枠の外では閉じない")
  }
}

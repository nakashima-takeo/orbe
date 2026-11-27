import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の diff のコメントの入口の flow（`testEditorPrComments` から撮る）。
extension DesignFlowSnapshotTests {
  /// コメントの入口（`editor_pr_comment_entry`。dark と light）: 行の頭の線 → 行に乗せた ＋ → 削除行から追加の行へ引いて
  /// いる範囲 → 離して開いた範囲の欄 → 範囲のスレッド → 左の列を閉じた並列の、左の面の ＋。
  func renderEntry(queriesRoot: URL) throws {
    let scene = try PrFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    // ポインタの位置を答える窓に載せる（面は窓の今のポインタの位置で ＋ を引き直すので、撮る間も ＋ が残る）。
    let window = PointerWindow(
      contentRect: NSRect(origin: .zero, size: Self.entrySize), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.answersAsKey = true
    window.pointer = NSPoint(x: -100, y: -100)
    window.contentView = scene.pane
    scene.pane.layoutSubtreeIfNeeded()
    defer { window.contentView = nil }
    pumpMain(until: { scene.isReady }, "PR の中身と帯が揃う")
    let steps = EntrySteps(scene: scene, window: window)
    try renderInPlace(
      scene.pane, name: "editor_pr_comment_entry", dir: previewDir("flows"),
      appearances: [true, false],
      steps: [
        ("lines", steps.open), ("hover", steps.hover), ("drag", steps.drag),
        ("range_draft", steps.release), ("range_thread", steps.rangeThread),
        ("side_hover", steps.sideHover),
      ])
  }

  private static let entrySize = NSSize(width: 1100, height: 760)
}

/// コメントの入口の flow の各ステップ。
@MainActor
private struct EntrySteps {
  let scene: PrFixtures.Scene
  let window: PointerWindow

  private var diff: EditorDiff? { scene.pane.diff }
  private var surface: MetalTextSurface? { diff?.newSurface as? MetalTextSurface }

  private func settle() {
    let scene = scene
    pumpMain(until: { scene.isDiffReady }, "PR の diff が揃う")
    for surface in scene.pane.diff.map(scene.pane.diffSurfaces) ?? [] {
      (surface as? MetalTextSurface)?.flush()
    }
  }

  /// 文書の行 `row` の中ほどの点。
  private func rowPoint(_ surface: MetalTextSurface, row: Int, x: CGFloat) -> CGPoint {
    CGPoint(
      x: x,
      y: surface.config.topInset + CGFloat(surface.rows.y(ofLine: row) - surface.scrollPosition.y)
        + surface.config.lineHeight / 2)
  }

  /// 文書の行 `boundary` の前の、差し込んだ行の塊の `line` 行目の中ほどの点。
  private func insertedPoint(
    _ surface: MetalTextSurface, boundary: Int, line: Int, x: CGFloat
  ) -> CGPoint? {
    let rows = surface.rows
    guard
      let block = rows.contents.indices.first(where: { index in
        guard rows.boundaries[index] == boundary, case .lines = rows.contents[index] else {
          return false
        }
        return true
      })
    else { return nil }
    return CGPoint(
      x: x,
      y: surface.config.topInset + CGFloat(rows.top(ofBlock: block) - surface.scrollPosition.y)
        + (CGFloat(line) + 0.5) * surface.config.lineHeight)
  }

  private func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
    guard let surface, let window = surface.textView.window,
      let event = NSEvent.mouseEvent(
        with: type, location: surface.textView.convert(point, to: nil), modifierFlags: [],
        timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)
    else { return XCTFail("前提: 面が窓にある") }
    switch type {
    case .leftMouseDown: surface.textView.mouseDown(with: event)
    case .leftMouseDragged: surface.textView.mouseDragged(with: event)
    default: surface.textView.mouseUp(with: event)
    }
  }

  private var column: CGFloat { Theme.Layout.editorPrMarkColumn / 2 }

  /// 窓のポインタを面 `surface` の点 `point` に置いて（nil なら窓の外へ）、ポインタの下の行を引き直させる。
  private func point(_ surface: MetalTextSurface, at point: CGPoint?) {
    window.pointer =
      point.map { surface.textView.convert($0, to: nil) } ?? NSPoint(x: -100, y: -100)
    surface.refreshPointer()
  }

  func open() {
    scene.openDiff()
    settle()
    surface?.scroll(toFirstLine: 4)
    settle()
  }

  /// 新しい側の行 7（空の文脈の行）にポインタを乗せる。
  func hover() {
    guard let surface else { return XCTFail("前提: 面がある") }
    point(surface, at: rowPoint(surface, row: 6, x: 300))
    settle()
  }

  /// 最初の削除行（古い側の行 9）の ＋ を押し、新しい側の行 10 まで引いたまま止める。
  func drag() {
    guard let surface, let start = insertedPoint(surface, boundary: 8, line: 0, x: column) else {
      return XCTFail("前提: 削除行がある")
    }
    point(surface, at: start)
    mouse(.leftMouseDown, at: start)
    let end = rowPoint(surface, row: 9, x: 200)
    window.pointer = surface.textView.convert(end, to: nil)
    mouse(.leftMouseDragged, at: end)
    settle()
  }

  /// 離す（範囲の欄が開く）。
  func release() {
    guard let surface else { return XCTFail("前提: 面がある") }
    mouse(.leftMouseUp, at: rowPoint(surface, row: 9, x: 200))
    point(surface, at: nil)
    settle()
  }

  /// 範囲の欄を閉じ、範囲のスレッド（新しい側の行 14〜16）を見せる。
  func rangeThread() {
    let range = DiffLineRange(
      start: DiffLine(version: .old, line: 8), end: DiffLine(version: .new, line: 9))
    diff?.comments?.draft(at: range)?.zone(.pressed(PrCommentControl.cancel))
    surface?.scroll(to: RowPosition(line: 12))
    settle()
  }

  /// 左の列を閉じて並列にし、左の面の削除行（古い側の行 10）に乗せる。
  func sideHover() {
    scene.pane.sidebar.setOpen(false)
    let pane = scene.pane
    pumpMain(until: { pane.diff.map { pane.diffSurfaces($0).count == 2 } ?? false }, "並列になる")
    settle()
    guard let left = diff?.oldSurface as? MetalTextSurface else { return XCTFail("前提: 左の面") }
    left.scroll(to: RowPosition(line: 4))
    settle()
    point(left, at: rowPoint(left, row: 9, x: 300))
    settle()
  }
}

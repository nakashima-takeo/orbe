import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の装備の flow（本物のコード片の 2 版を `LineDiff` で突き合わせる。→ `DiffRowsSample`）。見本 D 節の寸法と色で作った見え方——インライン
/// （番号 2 列・記号の列・追加 / 削除 / 文脈の地と字。削除は文書に無い行）と、並列（番号 1 列・詰め物の地の 2 面がスクロール
/// を共にする）——を撮る。読むだけの面に打鍵しても変わらないこと、2 列の面で追加の区間に行を足しても下の旧番号が変わら
/// ないこと、並列の片側を送ると両側が同じ位置へ動くこと、light の外観を撮る。見え方の値と見本との突き合わせは diff の画面を
/// 作る単位（d1）が持つ——ここはエンジンがその値を描けることを確かめるところまで。
extension DesignFlowSnapshotTests {
  func testEditorDiffRows() throws {
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では面を作らない")
    let flow = try DiffRowsFlow(directory: TestScratch.caseDir, queries: queriesRoot)
    try flow.shoot(
      "editor_diff_rows", to: previewDir("flows"),
      steps: [
        ("inline", flow.showInline),
        ("inline_typed", flow.typeIntoReadOnly),
        ("inline_added_above", flow.addLineInAddedBlock),
        ("side", flow.showSideBySide),
        ("side_scrolled", flow.scrollRightSide),
        ("inline_light", flow.showInlineInLight),
      ])
  }

  private var queriesRoot: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }
}

/// diff の flow の窓と面と手順。
@MainActor
private final class DiffRowsFlow {
  let window: NSWindow
  let container = NSView()
  let inline: Pane
  let left: Pane
  let right: Pane
  private let separator = NSView()

  /// 面と、それに結んだ文書。
  struct Pane {
    let surface: MetalTextSurface
    let document: EditorDocument
  }

  init(directory: URL, queries: URL) throws {
    let registry = LanguageRegistry(queriesRoot: queries)
    func pane(_ name: String, _ text: String, trailing: CGFloat) throws -> Pane {
      let url = directory.appendingPathComponent(name)
      try Data(text.utf8).write(to: url)
      let surface = MetalTextSurface(
        style: DiffRowsSample.style(trailing: trailing), omittedLabel: { "+\($0)" })
      let document = EditorDocument(
        url: url, contents: try EditorDocument.read(url), surface: surface, registry: registry)
      XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30))
      return Pane(surface: surface, document: document)
    }
    inline = try pane("LineDiff.swift", DiffSample.new, trailing: 6)
    left = try pane("LineDiff.old.swift", DiffSample.old, trailing: 8)
    right = try pane("LineDiff.new.swift", DiffSample.new, trailing: 8)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 480), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    container.wantsLayer = true
    container.frame = NSRect(x: 0, y: 0, width: 1000, height: 480)
    window.contentView = container
    separator.wantsLayer = true
    let sample = DiffRowsSample.diff(old: DiffSample.old, new: DiffSample.new)
    inline.surface.setPresentation(DiffRowsSample.inlinePresentation)
    inline.surface.setRows(sample.inline)
    inline.surface.isEditable = false
    for (pane, side) in [(left, DiffRowsSample.Side.old), (right, .new)] {
      pane.surface.setPresentation(DiffRowsSample.sidePresentation)
      pane.surface.setRows(sample.side(side))
      pane.surface.isEditable = false
    }
    left.surface.shareScroll(with: right.surface)
  }

  /// 窓の地と区切りの色を今の外観で塗る。
  private func paint() {
    window.appearance?.performAsCurrentDrawingAppearance {
      container.layer?.backgroundColor = Theme.Color.bgBase.cgColor
      separator.layer?.backgroundColor = DiffRowsSample.hairline.cgColor
    }
  }

  /// 面 `panes` を窓に並べる（並列は 2 面の間に 1px の区切り）。
  private func arrange(_ panes: [Pane]) {
    container.subviews.forEach { $0.removeFromSuperview() }
    let width = container.bounds.width
    let height = container.bounds.height
    let each = (width - CGFloat(panes.count - 1)) / CGFloat(panes.count)
    for (index, pane) in panes.enumerated() {
      let view = pane.surface.view
      view.frame = NSRect(x: CGFloat(index) * (each + 1), y: 0, width: each, height: height)
      container.addSubview(view)
      pane.surface.viewStateDidChange(
        size: view.frame.size, scale: window.backingScaleFactor, visible: false)
    }
    if panes.count == 2 {
      separator.frame = NSRect(x: each, y: 0, width: 1, height: height)
      container.addSubview(separator)
    }
    paint()
  }

  func showInline() {
    arrange([inline])
  }

  /// 読むだけの面に打鍵・改行・削除・IME の変換を送る（本文は変わらない）。
  func typeIntoReadOnly() {
    window.makeFirstResponder(inline.surface.responder)
    let view = inline.surface.textView
    inline.surface.selectedRange = NSRange(location: inline.document.text.lineStart(3), length: 0)
    for character in "zzz" { view.insertText(String(character)) }
    view.insertNewline(nil)
    view.deleteBackward(nil)
    view.setMarkedText(
      "へんしん", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(
      inline.document.text.substring(NSRange(location: 0, length: inline.document.text.length)),
      DiffSample.new, "読むだけの面の本文は変わらない")
  }

  /// 編集できる 2 列の面で、追加の区間の 1 行目の後に行を足す（下の文脈の旧番号は変わらず、自分の番号だけ進む）。
  func addLineInAddedBlock() {
    let surface = inline.surface
    surface.isEditable = true
    guard let added = surface.rows.spans.first(where: { $0.style == DiffRowsSample.added }) else {
      return XCTFail("前提: 追加の区間がある")
    }
    let text = inline.document.text
    surface.selectedRange = NSRange(
      location: NSMaxRange(text.contentRange(ofRow: added.line)), length: 0)
    surface.textView.insertText("\n    // 足した行")
    surface.isEditable = false
  }

  func showSideBySide() {
    arrange([left, right])
  }

  /// 右の面を指で送る（左の面も同じ位置へ動く）。
  func scrollRightSide() {
    let surface = right.surface
    let t = CACurrentMediaTime()
    surface.scroll(ScrollInput(timestamp: t, delta: .zero, precise: true, phase: .began))
    surface.scroll(
      ScrollInput(timestamp: t + 0.01, delta: SIMD2(0, -150), precise: true, phase: .changed))
    surface.scroll(ScrollInput(timestamp: t + 0.02, delta: .zero, precise: true, phase: .ended))
    XCTAssertEqual(left.surface.scrollPosition, surface.scrollPosition, "左右は同じ位置")
  }

  func showInlineInLight() {
    window.appearance = NSAppearance(named: .aqua)
    arrange([inline])
  }

  /// 手順ごとに窓の中身を撮る（名前と置き場は他の flow と同じ）。
  func shoot(
    _ name: String, to directory: URL, steps: [(label: String, action: () -> Void)]
  ) throws {
    defer { window.contentView = nil }
    for (index, step) in steps.enumerated() {
      step.action()
      for pane in [inline, left, right] { pane.surface.flush() }
      container.layoutSubtreeIfNeeded()
      let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
      container.cacheDisplay(in: container.bounds, to: rep)
      let url = directory.appendingPathComponent(
        String(format: "%@_%02d_%@.png", name, index, step.label))
      try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }
}

/// 本物のコード片（`LineDiff.swift` の頭）の 2 版——旧版から 2 行を消し、3 行を書き換え、4 行を足したもの。
private enum DiffSample {
  static let new = """
    import Foundation

    /// baseline と本文の行差分の 1 区間（`@@ -oldStart,oldCount +newStart,newCount @@` と同じ形）。
    public struct LineHunk: Equatable, Sendable {
      public let oldStart: Int
      public let oldCount: Int
      public let newStart: Int
      public let newCount: Int

      public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
      }
    }

    /// 行差分の純関数。行は `\\n` で割り、末尾の改行の有無も行の違いとして扱う。
    public enum LineDiff {
      /// 差分を取る残りの行数（両側の和）の上限。
      public static let maximumComparedLines = 1_000

      public static func hunks(base: String, current: TextRope) -> [LineHunk] {
        let baseUnits = ContiguousArray(base.utf16)
        let currentUnits = current.contiguousUnits()
        let old = lines(of: baseUnits)
        let new = lines(of: currentUnits)
        let (prefix, suffix) = commonEnds(old, new)
        let oldRest = old[prefix..<(old.count - suffix)]
        let newRest = new[prefix..<(new.count - suffix)]
        guard !oldRest.isEmpty || !newRest.isEmpty else { return [] }
        guard oldRest.count + newRest.count <= maximumComparedLines else {
          return [
            hunk(oldStart: prefix, oldCount: oldRest.count, newStart: prefix, newCount: newRest.count)
          ]
        }
        let difference = newRest.difference(from: oldRest)
        return collect(difference, offset: prefix)
      }
    }

    """

  static let old = """
    import Foundation

    /// baseline と本文の行差分の 1 区間。
    public struct LineHunk: Equatable {
      public let oldStart: Int
      public let oldCount: Int
      public let newStart: Int
      public let newCount: Int
    }

    /// 行差分の純関数。
    public enum LineDiff {
      /// 差分を取る残りの行数の上限。
      public static let maximumComparedLines = 500

      public static func hunks(base: String, current: TextRope) -> [LineHunk] {
        let baseUnits = ContiguousArray(base.utf16)
        let currentUnits = current.contiguousUnits()
        let old = lines(of: baseUnits)
        let new = lines(of: currentUnits)
        // 先頭と末尾の共通の行を落とす。
        // 落とした残りだけを比べる。
        let (prefix, suffix) = commonEnds(old, new)
        let oldRest = old[prefix..<(old.count - suffix)]
        let newRest = new[prefix..<(new.count - suffix)]
        guard !oldRest.isEmpty || !newRest.isEmpty else { return [] }
        let difference = newRest.difference(from: oldRest)
        return collect(difference, offset: prefix)
      }
    }

    """
}

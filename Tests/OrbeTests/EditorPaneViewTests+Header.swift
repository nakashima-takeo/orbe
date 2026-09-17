import AppKit
import XCTest

@testable import Orbe

/// 列の頭——pane が確保する高さ（ファイルタブ行 ＋ hairline、文書があればパンくず）を SwiftUI の中身がそのまま
/// 埋め、文書が無くてもファイルタブ行の帯は残る。pane の矩形と SwiftUI の寸法は別々に書かれているので、
/// 片側だけ変わればここで割れる。
///
/// 壊れると何が起きるか。頭の帯の下に透明な隙間が出る、またはパンくずが本体の上に食い込んで下端で切れる。
@MainActor
final class EditorPaneViewHeaderTests: OrbeTestCase {
  func testColumnHeadContentFillsTheReservedHeightWithAndWithoutADocument() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 900)
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))  // SwiftUI の描画コミット

    XCTAssertEqual(pane.headerHeight, 29)
    XCTAssertEqual(pane.headerHost.fittingSize.height, 29, "文書が無ければタブ行の帯だけ")
    let probe = try PixelProbe(pane)
    XCTAssertFalse(
      PixelProbe.same(
        try probe.rgb(pane.bodyRect.midX, 14), try probe.rgb(pane.bodyRect.midX, 200)),
      "文書が無くてもファイルタブ行の帯（沈み面）は本体の地と違う色で残る")

    _ = try tab.editor.open(try caseFile("a.swift", "let a = 1\n"))
    tab.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(pane.headerHeight, 49)
    XCTAssertEqual(pane.headerHost.fittingSize.height, 49, "文書があればパンくずの段が加わる")
  }

  /// ファイルタブ行は自然幅のタブを並べ、溢れれば横スクロールし、アクティブが変われば可視位置へ送る。
  func testFileTabsOverflowScrollsToTheActiveTab() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 400)
    defer { window.orderOut(nil) }
    pane.shell.toggleSidebar()  // 列を本体だけにして溢れを作る（本体 363）
    let documents = try (0..<8).map { index in
      try tab.editor.open(try caseFile("a-long-file-name-\(index).swift", "x"))
    }
    let scroll = try XCTUnwrap(scrollView(in: pane.headerHost))
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    pumpMain(until: { scroll.documentVisibleRect.minX > 0 }, "末尾のタブがアクティブなら可視位置へ")

    tab.editor.activate(documents[0])
    pumpMain(until: { scroll.documentVisibleRect.minX == 0 }, "先頭へ戻ればスクロールも戻る")
  }

  private func scrollView(in view: NSView) -> NSScrollView? {
    for subview in view.subviews {
      if let scroll = subview as? NSScrollView { return scroll }
      if let scroll = scrollView(in: subview) { return scroll }
    }
    return nil
  }

  private struct PixelProbe {
    let rep: NSBitmapImageRep
    let scale: CGFloat

    init(_ pane: EditorPaneView) throws {
      rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      scale = CGFloat(rep.pixelsWide) / pane.bounds.width
    }

    func rgb(_ x: CGFloat, _ y: CGFloat) throws -> [Int] {
      let c = try XCTUnwrap(
        rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
      return [c.redComponent, c.greenComponent, c.blueComponent].map { Int($0 * 255) }
    }

    static func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }
  }
}

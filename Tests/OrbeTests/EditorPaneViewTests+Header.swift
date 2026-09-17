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

    XCTAssertEqual(pane.headerHeight, 29)
    pumpMain(until: { pane.headerHost.fittingSize.height == 29 }, "文書が無ければタブ行の帯だけ")
    let x = pane.bodyRect.midX
    let probe = try probe(pane) { p in !PaneProbe.same(try p.rgb(x, y: 14), try p.rgb(x, y: 200)) }
    XCTAssertFalse(
      PaneProbe.same(try probe.rgb(x, y: 14), try probe.rgb(x, y: 200)),
      "文書が無くてもファイルタブ行の帯（沈み面）は本体の地と違う色で残る")

    _ = try tab.editor.open(try caseFile("a.swift", "let a = 1\n"))
    tab.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(pane.headerHeight, 49)
    pumpMain(until: { pane.headerHost.fittingSize.height == 49 }, "文書があればパンくずの段が加わる")
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
    pumpMain(until: { scroll.documentVisibleRect.minX > 0 }, "末尾のタブがアクティブなら可視位置へ")

    tab.editor.activate(documents[0])
    pumpMain(until: { scroll.documentVisibleRect.minX == 0 }, "先頭へ戻ればスクロールも戻る")
  }
}

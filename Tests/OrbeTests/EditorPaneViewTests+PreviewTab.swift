import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 仮の文書の骨——エクスプローラーのファイル行は 1 回目の押下で仮の文書として開き（ダブルクリックの判定を待たない）、
/// 2 回目（ダブルクリック）で普通の文書にする。
///
/// 壊れると何が起きるか。エクスプローラーで見て回るたびに開いている文書が増える。シングルクリックで開くのがダブルクリック
/// の猶予だけ遅れる。ダブルクリックしても仮のままで、次のクリックで開いていたファイルが消える。
@MainActor
final class EditorPaneViewPreviewTabTests: OrbeTestCase {
  private struct Hosted {
    let tab: TerminalTab
    let window: NSWindow
    @MainActor var pane: EditorPaneView { tab.group.view.editor }
  }

  /// 根に a.txt・b.txt・c.txt を置いた幅 900 の面（エクスプローラーを出す）。窓は並べない。
  private func host() throws -> Hosted {
    for name in ["a.txt", "b.txt", "c.txt"] { _ = try caseFile(name, name) }
    let tab = TerminalTab.alone(
      cwd: TestScratch.caseDir.path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900)
    window.appearance = NSAppearance(named: .darkAqua)
    pumpMain(
      until: {
        Set(tab.group.view.editor.tree.rows.map(\.name)).isSuperset(of: ["a.txt", "b.txt", "c.txt"])
      },
      "ファイルの行が出る")
    return Hosted(tab: tab, window: window)
  }

  /// ツリーの `name` の行の中ほど（面の座標。上の行の下）。
  private func treeRow(_ hosted: Hosted, _ name: String) throws -> NSPoint {
    let index = try XCTUnwrap(hosted.pane.tree.rows.firstIndex { $0.name == name })
    return NSPoint(
      x: 80,
      y: Theme.Layout.editorBar + Theme.Layout.editorTreeField + 2 * Theme.Layout.editorTreeTopPad
        + Theme.Layout.editorRow * (CGFloat(index) + 0.5))
  }

  private func names(_ hosted: Hosted) -> [String] {
    hosted.tab.group.editor.documents.map(\.url.lastPathComponent)
  }

  func testTreeRowsOpenAPreviewOnTheFirstClickAndPinOnTheSecond() throws {
    let hosted = try host()
    placeOffscreen(hosted.window)
    let editor = hosted.tab.group.editor

    try click(hosted.pane, at: try treeRow(hosted, "a.txt"))
    pumpMain(
      until: { self.names(hosted) == ["a.txt"] }, timeout: NSEvent.doubleClickInterval / 2,
      "1 回目ですぐ開く（ダブルクリックの判定を待たない）")
    XCTAssertTrue(editor.preview === editor.activeDocument, "仮の文書")
    try click(hosted.pane, at: try treeRow(hosted, "b.txt"))
    pumpMain(until: { self.names(hosted) == ["b.txt"] }, "次のファイルが仮の文書を入れ替える")

    try click(hosted.pane, at: try treeRow(hosted, "b.txt"), count: 2)
    pumpMain(until: { editor.preview == nil }, "2 回目で普通の文書")
    try click(hosted.pane, at: try treeRow(hosted, "c.txt"))
    pumpMain(
      until: { self.names(hosted) == ["c.txt", "b.txt"] }, "普通の文書は残り、別の仮の文書が先頭に開く")
    XCTAssertEqual(editor.preview?.url.lastPathComponent, "c.txt")
  }
}

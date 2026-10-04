import AppKit
import XCTest

@testable import Orbe

/// 仮のタブの骨——エクスプローラーのファイル行は 1 回目の押下で仮のタブで開き（ダブルクリックの判定を待たない）、2 回目
/// （ダブルクリック）で普通のタブにする。ファイルタブのダブルクリックも普通のタブにする。仮のタブの地には斜線が見える。
///
/// 壊れると何が起きるか。エクスプローラーで見て回るたびにタブが増える。シングルクリックで開くのがダブルクリックの猶予
/// だけ遅れる。ダブルクリックしても仮のままで、次のクリックで開いていたファイルが消える。仮のタブが普通のタブと見分け
/// られない。
@MainActor
final class EditorPaneViewPreviewTabTests: OrbeTestCase {
  private struct Hosted {
    let tab: TerminalTab
    let window: NSWindow
    @MainActor var pane: EditorPaneView { tab.view.editor }
  }

  /// 根に a.txt・b.txt・c.txt を置いた幅 900 の面（エクスプローラーを出す）。窓は物理画面の外へ並べる（`sendEvent` は
  /// ordered-in の窓にしか配送しない）。
  private func host() throws -> Hosted {
    for name in ["a.txt", "b.txt", "c.txt"] { _ = try caseFile(name, name) }
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900)
    window.appearance = NSAppearance(named: .darkAqua)
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFront(nil)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    pumpMain(
      until: {
        Set(tab.view.editor.tree.rows.map(\.name)).isSuperset(of: ["a.txt", "b.txt", "c.txt"])
      },
      "ファイルの行が出る")
    return Hosted(tab: tab, window: window)
  }

  /// ツリーの `name` の行の中ほど（面の座標。パネルヘッダーと根の行の下）。
  private func treeRow(_ hosted: Hosted, _ name: String) throws -> NSPoint {
    let index = try XCTUnwrap(hosted.pane.tree.rows.firstIndex { $0.name == name })
    return NSPoint(
      x: Theme.Layout.editorRail + 80,
      y: Theme.Layout.editorPanelHeader + Theme.Layout.editorRow * (CGFloat(index) + 1.5))
  }

  private func names(_ hosted: Hosted) -> [String] {
    hosted.tab.editor.documents.map(\.url.lastPathComponent)
  }

  func testTreeRowsOpenAPreviewOnTheFirstClickAndPinOnTheSecond() throws {
    let hosted = try host()
    let editor = hosted.tab.editor

    try click(hosted.pane, at: try treeRow(hosted, "a.txt"))
    pumpMain(
      until: { self.names(hosted) == ["a.txt"] }, timeout: NSEvent.doubleClickInterval / 2,
      "1 回目ですぐ開く（ダブルクリックの判定を待たない）")
    XCTAssertTrue(editor.preview === editor.activeDocument, "仮のタブ")
    try click(hosted.pane, at: try treeRow(hosted, "b.txt"))
    pumpMain(until: { self.names(hosted) == ["b.txt"] }, "次のファイルが仮のタブを入れ替える")

    try click(hosted.pane, at: try treeRow(hosted, "b.txt"), count: 2)
    pumpMain(until: { editor.preview == nil }, "2 回目で普通のタブ")
    try click(hosted.pane, at: try treeRow(hosted, "c.txt"))
    pumpMain(until: { self.names(hosted) == ["b.txt", "c.txt"] }, "普通のタブは残り、別の仮のタブが開く")
    XCTAssertEqual(editor.preview?.url.lastPathComponent, "c.txt")
  }

  /// ファイルタブのダブルクリックで普通のタブになる。1 回目の押下は今どおりの切替。
  func testDoubleClickingAFileTabPinsIt() throws {
    let hosted = try host()
    let pane = hosted.pane
    let editor = hosted.tab.editor
    try editor.open(try caseFile("a.txt", "a.txt"), as: .pinned)
    let preview = try editor.open(try caseFile("b.txt", "b.txt"), as: .preview)
    try editor.open(try caseFile("c.txt", "c.txt"), as: .pinned)
    _ = try probe(pane) { _ in pane.shell.tabs.map(\.isPreview) == [false, true, false] }
    let middle = NSPoint(x: fileTabSlotCenter(pane, 1).x - 30, y: Theme.Layout.editorFileTabs / 2)

    try click(pane, at: middle)
    pumpMain(until: { editor.activeDocument === preview }, "押すと切り替わる")
    XCTAssertTrue(editor.preview === preview, "1 回目では仮のまま")
    try click(pane, at: middle, count: 2)
    pumpMain(until: { editor.preview == nil }, "ダブルクリックで普通のタブ")
  }

  /// 仮のタブの地には斜線がうっすら見え（地の色が揺れる）、普通のタブの地は一様。
  func testThePreviewTabHasAHatchedGround() throws {
    let hosted = try host()
    let pane = hosted.pane
    let editor = hosted.tab.editor
    try editor.open(try caseFile("a.txt", "a.txt"), as: .pinned)
    try editor.open(try caseFile("b.txt", "b.txt"), as: .preview)
    try editor.open(try caseFile("c.txt", "c.txt"), as: .pinned)
    let spread = { (probe: PaneProbe, index: Int) throws -> Int in
      let right = self.fileTabSlotCenter(pane, index).x - Theme.Layout.editorTabClose
      let sums = try stride(from: right - 30, to: right, by: 1).map {
        try probe.rgb($0, y: Theme.Layout.editorFileTabs - 3).reduce(0, +)
      }
      return (sums.max() ?? 0) - (sums.min() ?? 0)
    }
    let drawn = try probe(pane) { try spread($0, 1) >= 6 }
    XCTAssertGreaterThanOrEqual(try spread(drawn, 1), 6, "仮のタブの地は揺れる")
    XCTAssertLessThanOrEqual(try spread(drawn, 0), 1, "普通のタブの地は一様")
  }
}

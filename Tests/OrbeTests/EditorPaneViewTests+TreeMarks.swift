import AppKit
import OrbeTestSupport
import XCTest

@testable import Orbe

/// ツリーの開いている文書の行の印と ×: 開いている文書の行に × が出て、未保存なら丸に替わり、× で文書を閉じる（未保存なら
/// 確認が出て、キャンセルなら閉じない）。× で閉じた後に続けた押下（ダブルクリックの 2 回目）は、× が消えて行だけが残った所に届いても、
/// 行を開き直さない。
///
/// 壊れると何が起きるか。ツリーの印が、開いている文書・未保存の状態とずれる。未保存の文書が × で確認なしに閉じて、編集が
/// 消える。× をダブルクリックすると、閉じた文書が普通の文書として開き直る。
@MainActor
final class EditorPaneViewTreeMarksTests: OrbeTestCase {
  private struct Hosted {
    let tab: TerminalTab
    let window: NSWindow
    @MainActor var pane: EditorPaneView { tab.group.view.editor }
    @MainActor var session: EditorSession { tab.group.editor }
  }

  /// 根に a.txt・b.txt を置いた幅 900 の面（エクスプローラーを出す）。窓は並べない。
  private func host() throws -> Hosted {
    for name in ["a.txt", "b.txt"] { _ = try caseFile(name, name) }
    let tab = TerminalTab.alone(
      cwd: TestScratch.caseDir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900)
    pumpMain(
      until: {
        Set(tab.group.view.editor.tree.rows.map(\.name)).isSuperset(of: ["a.txt", "b.txt"])
      },
      "ファイルの行が出る")
    return Hosted(tab: tab, window: window)
  }

  private func mark(_ hosted: Hosted, _ name: String) -> EditorItemListRow.Mark? {
    hosted.pane.tree.rows.first { $0.name == name }?.mark
  }

  private func names(_ hosted: Hosted) -> [String] {
    hosted.session.documents.map(\.url.lastPathComponent)
  }

  /// ツリーの `name` の行の、印の枠の中ほど（面の座標。git 管理外なので行の右端に git の字は無い）。
  private func markPoint(_ hosted: Hosted, _ name: String) throws -> NSPoint {
    let index = try XCTUnwrap(hosted.pane.tree.rows.firstIndex { $0.name == name })
    return NSPoint(
      x: hosted.pane.sideHost.frame.maxX - Theme.Layout.editorTreeInset
        - Theme.Layout.editorTreeRowPadX - Theme.Layout.editorTreeChipGap
        - Theme.Layout.editorItemListMark / 2,
      y: Theme.Layout.editorBar + Theme.Layout.editorTreeField + 2 * Theme.Layout.editorTreeTopPad
        + Theme.Layout.editorRow * (CGFloat(index) + 0.5))
  }

  func testOpenDocumentsCarryTheirMarkAndClosingAnUnsavedOneAsks() throws {
    let hosted = try host()
    let a = try hosted.session.open(
      TestScratch.caseDir.appendingPathComponent("a.txt"), as: .pinned)
    pumpMain(until: { self.mark(hosted, "a.txt") == .close }, "開いている文書の行に ×")
    XCTAssertNil(mark(hosted, "b.txt"), "開いていない行には出ない")

    a.surface.responder.perform(Selector(("insertText:")), with: "x")
    pumpMain(until: { self.mark(hosted, "a.txt") == .unsaved }, "未保存なら丸")

    hosted.pane.shell.closeDocument(a.url, .zero)
    let sheet = try XCTUnwrap(hosted.window.attachedSheet, "確認が出る")
    hosted.window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
    XCTAssertEqual(names(hosted), ["a.txt"], "キャンセルなら閉じない")

    hosted.pane.shell.closeDocument(a.url, .zero)
    let again = try XCTUnwrap(hosted.window.attachedSheet)
    hosted.window.endSheet(again, returnCode: .alertSecondButtonReturn)
    XCTAssertEqual(names(hosted), [], "「保存しない」なら閉じる")
    pumpMain(until: { self.mark(hosted, "a.txt") == nil }, "閉じれば印が消える")
  }

  /// × を押して閉じた後に続けた押下（ダブルクリックの 2 回目）は、× が消えて行だけが残った所に届いても、閉じた文書を開き
  /// 直さない。対: × の無い行の同じ位置を同じように押せば、押した後に確かめる同じ時点で、もう開いている（確かめる時点が、
  /// 押下が行に届いた後であること）。
  func testTheSecondPressOfADoubleClickOnTheMarkDoesNotReopenTheClosedFile() throws {
    let hosted = try host()
    placeOffscreen(hosted.window)
    _ = try hosted.session.open(TestScratch.caseDir.appendingPathComponent("a.txt"), as: .pinned)
    pumpMain(until: { self.mark(hosted, "a.txt") == .close }, "前提: × が出る")
    flush(hosted.window)

    try click(hosted.pane, at: try markPoint(hosted, "a.txt"))
    pumpMain(until: { self.names(hosted).isEmpty }, "× で閉じる")
    flush(hosted.window)
    try click(hosted.pane, at: try markPoint(hosted, "a.txt"), count: 2)
    flush(hosted.window)
    XCTAssertEqual(names(hosted), [], "続きの押下で開き直さない")

    try click(hosted.pane, at: try markPoint(hosted, "b.txt"))
    try click(hosted.pane, at: try markPoint(hosted, "b.txt"), count: 2)
    flush(hosted.window)
    XCTAssertEqual(names(hosted), ["b.txt"], "対: × の無い行は、同じ時点で開いている")
    XCTAssertNil(hosted.session.preview, "対: 2 回目で普通の文書")
  }
}

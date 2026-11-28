import AppKit
import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の画面のキー v——本体の PR の diff のファイルの確認済みを付け外しする。焦点が diff の面（読むだけの場）・面の器・PR の
/// パネルの列にあるときだけ働き、コメントの欄で打っている間は字として入る（列から押したときは `PullRequestPaneTests`）。
///
/// 壊れると何が起きるか: v で確認済みが付かない。返信を打っている最中に v を打つと確認済みが切り替わって字が入らない。押し続ける
/// と付け外しを繰り返す。↑↓ の直後に v を押すと、列で強調している行と違うファイルの確認済みを GitHub へ書く。
extension EditorDiffTests {
  private var viewedKey: NSEvent { .key("v", []) }

  /// 本文（読むだけ）に焦点があれば、v で確認済みが付き、もう一度で外れる。押し続けて届く繰り返しは、付け外しせずに飲む。
  func testVTogglesViewedFromTheDiffBody() throws {
    let (diff, tab) = try commentedTab(Remote())
    let pane = tab.group.view.editor
    guard case .pullRequest(let state) = diff.id.kind else { return XCTFail("前提: PR の diff") }
    let window = try XCTUnwrap(pane.window)
    window.makeFirstResponder(try XCTUnwrap(diff.newSurface).responder)

    XCTAssertTrue(pane.handleViewedKey(viewedKey))
    XCTAssertTrue(state.isViewed("a.txt"))
    XCTAssertTrue(pane.handleViewedKey(.key("v", [], isRepeat: true)), "繰り返しは飲む")
    XCTAssertTrue(state.isViewed("a.txt"), "繰り返しでは外れない")
    XCTAssertTrue(pane.handleViewedKey(viewedKey))
    XCTAssertFalse(state.isViewed("a.txt"))
    XCTAssertFalse(pane.handleViewedKey(.key("v")), "⌘v は扱わない")
  }

  /// 返信・新しいコメントの欄で打っている間は、v を扱わない（字として欄に入る）。
  func testVIsTypedIntoACommentField() throws {
    let (diff, tab) = try commentedTab(Remote())
    let pane = tab.group.view.editor
    guard case .pullRequest(let state) = diff.id.kind else { return XCTFail("前提: PR の diff") }
    let surface = try engine(diff.newSurface)
    let window = try XCTUnwrap(pane.window)
    window.makeFirstResponder(surface.responder)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(1), to: .document(1))
    XCTAssertNotNil(layer.draft(at: .at(.new, 1)), "前提: 欄に焦点")

    XCTAssertFalse(pane.handleViewedKey(viewedKey))
    XCTAssertFalse(state.isViewed("a.txt"))
  }

  /// Changes の diff では働かない（v は本文に字として入る）。
  func testVDoesNothingInAChangesDiff() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, window) = tab()
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    tab.group.editor.selectScreen(.changes)
    waitRows(diff, "変更が出る") { !$0.isEmpty }
    window.makeFirstResponder(try XCTUnwrap(diff.newSurface).responder)
    XCTAssertFalse(pane.handleViewedKey(viewedKey))
  }
}

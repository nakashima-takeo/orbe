import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// diff の見せ方は本体の幅で決まる——窓の幅・左の列の開閉のどちらで本体の幅が変わっても見せ方が替わり、面が見えていない間に
/// 幅が変わっても、見えたときの幅で決まる。PR のコメントの欄で打っている最中に替わっても、欄は主のまま残る。
///
/// 壊れると何が起きるか: 広い窓でもインラインのまま・狭い窓でも並列のまま。制御 API で開いた diff や、⌘E で閉じている間に
/// 窓の幅が変わった diff が、幅に合わない見せ方で出る。⌘B で左の列を閉じただけで、古い側の行にあるスレッドの返信の欄から
/// 焦点が外れて続きの打鍵が捨てられたり、開いただけの新しいコメントの欄が消えたりする。
extension EditorDiffTests {
  /// 左の列を閉じて本体が広がれば並列になり、開いて狭まればインラインに戻る。
  func testClosingTheSidebarWidensTheBodyIntoSideBySide() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let (tab, _) = tab(width: Theme.Layout.editorDiffSideWidth + 100)
    let pane = tab.group.view.editor
    let diff = try tab.group.editor.openDiff(id("a.txt", .workingTree))
    waitRows(diff, "前提: 左の列を開いた本体ではインライン") { self.removedLines($0) == [1] }
    XCTAssertEqual(diff.presented, .inline)

    pane.sidebar.setOpen(false)
    pumpMain(until: { diff.presented == .side && pane.diffSurfaces(diff).count == 2 }, "並列")
    pane.sidebar.setOpen(true)
    pumpMain(until: { diff.presented == .inline && pane.diffSurfaces(diff).count == 1 }, "インライン")
  }

  /// 面が見えていない間に開いた diff と、見えていない間に本体の幅が変わった diff は、面が見えたときの本体の幅で見せ方が
  /// 決まる（制御 API が、窓に載っていない連に diff を開く・⌘E で閉じている間に窓の幅が変わる）。
  func testADiffShowsTheModeOfTheBodyOnceTheFaceIsVisible() throws {
    try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    addTeardownBlock { withExtendedLifetime(tab) {} }
    try tab.group.openDiff(id("a.txt", .workingTree))
    let window = hostEditor(tab, width: Self.sideWidth)
    let pane = tab.group.view.editor
    let diff = try XCTUnwrap(pane.diff)
    pumpMain(until: { diff.presented == .side && pane.diffSurfaces(diff).count == 2 }, "窓に載って並列")

    tab.group.view.show(.terminal, animated: false)
    resize(window, width: 900)
    tab.group.view.show(.editor, animated: false)
    pumpMain(until: { diff.presented == .inline && pane.diffSurfaces(diff).count == 1 }, "見えてインライン")
  }

  /// インラインで、古い側の行のスレッドの返信の欄に打っている間に並列へ替わっても、欄は左の面で主のまま残り、窓の焦点も左の面に
  /// 移る。インラインへ戻れば、欄は右の面で主になる。
  func testAReplyOnAnOldSideLineStaysFocusedAcrossTheModes() throws {
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", side: .old, line: 3, isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
    ]
    let (diff, right) = try commentedDiff(remote)
    let window = try XCTUnwrap(right.textView.window)
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { right.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "前提: 削除行の下に置かれる")
    window.makeFirstResponder(right.textView)
    right.focus(zone.field)
    right.replaceText(of: zone.field, with: "返信")

    resize(window, width: Self.sideWidth)
    let left = try engine(diff.oldSurface)
    XCTAssertEqual(left.primary, .field(zone.field.id), "左の面で主のまま")
    XCTAssertTrue(window.firstResponder === left.textView, "窓の焦点も左の面")
    left.replaceText(of: zone.field, with: "返信の続き")
    XCTAssertEqual(zone.text, "返信の続き")

    resize(window, width: 900)
    XCTAssertNil(diff.oldSurface)
    XCTAssertEqual(right.primary, .field(zone.field.id), "インラインに戻れば右の面で主")
    XCTAssertTrue(window.firstResponder === right.textView)
  }

  /// インラインで古い側の行に開いただけの新しいコメントの欄（本文が空）は、並列へ替わっても閉じず、左の面で主のまま残る。
  func testAnEmptyDraftOnAnOldSideLineSurvivesTheSwitch() throws {
    let (diff, right) = try commentedDiff(Remote())
    let window = try XCTUnwrap(right.textView.window)
    let layer = try XCTUnwrap(diff.comments)
    window.makeFirstResponder(right.textView)
    layer.surface(right, didMarkFrom: .source(2), to: .source(2))
    let draft = try XCTUnwrap(layer.draft(.old, line: 2))

    resize(window, width: Self.sideWidth)
    XCTAssertIdentical(layer.draft(.old, line: 2), draft, "欄は閉じない")
    XCTAssertEqual(try engine(diff.oldSurface).primary, .field(draft.field.id))
    XCTAssertEqual(right.primary, .body)
  }

  /// 新しい側の行の欄は、どちらの見せ方でも右の面にあり、替わっても主のまま。
  func testADraftOnANewSideLineStaysFocusedAcrossTheModes() throws {
    let (diff, right) = try commentedDiff(Remote())
    let window = try XCTUnwrap(right.textView.window)
    let layer = try XCTUnwrap(diff.comments)
    window.makeFirstResponder(right.textView)
    layer.surface(right, didMarkFrom: .document(1), to: .document(1))
    let draft = try XCTUnwrap(layer.draft(.new, line: 1))

    resize(window, width: Self.sideWidth)
    XCTAssertNotNil(diff.oldSurface, "前提: 並列")
    XCTAssertEqual(right.primary, .field(draft.field.id))
    XCTAssertTrue(window.firstResponder === right.textView)
    resize(window, width: 900)
    XCTAssertIdentical(layer.draft(.new, line: 1), draft)
    XCTAssertEqual(right.primary, .field(draft.field.id))
  }
}

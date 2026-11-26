import AppKit
import OrbeEditorCore
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 面の中の確認（`EditorConfirm`）を本物の面に載せたときの押下・閉じ方・フォーカス。確定の処理は偽物で、行った回数を記録する。
///
/// 壊れると何が起きるか。「キャンセル」や幕の押下で、取り返しのつかない破棄が走る。確認の裏のバー・左の列・本体が押せて、
/// 確認を出したまま別の操作が走る。閉じた後も面が押せない。確認を出した後に cd・画面の切り替え・⌘E が起きても確認が残り、
/// 前の根のファイルを捨てる「破棄」が押せる。フォーカスが外へ移っても確認が残り、幕の裏へ打鍵が届く。esc の後、フォーカスが
/// どこにも無い。
@MainActor
final class EditorConfirmTests: OrbeTestCase {
  struct Hosted {
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    let document: EditorDocument
    @MainActor var confirm: EditorConfirm { pane.confirm }
  }

  private let content = EditorConfirmContent(
    title: "a.txt の変更を破棄しますか？", message: "この操作は元に戻せません。", confirmTitle: "破棄",
    label: "変更を破棄")
  /// 確定の処理を行った回数。
  private var confirmed = 0

  /// 文書を 1 つ開いた面（Files の画面）を窓に載せ、本文にフォーカスを置く。
  private func host() throws -> Hosted {
    let tab = TerminalTab.alone(
      cwd: TestScratch.caseDir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 900, height: 600)
    let document = try tab.group.editor.open(try caseFile("a.txt", "a"), as: .pinned)
    window.makeFirstResponder(document.surface.responder)
    return Hosted(tab: tab, pane: tab.group.view.editor, window: window, document: document)
  }

  private func show(_ hosted: Hosted) {
    hosted.confirm.show(content) { [weak self] in self?.confirmed += 1 }
    XCTAssertTrue(hosted.pane.focusIsInConfirm, "前提: 確認がフォーカスを持つ")
  }

  /// 確認が出ている間は、面のどこ（上のバー・左の列・本体）を押しても確認が受け、裏の view へ届かない。閉じた後は、押下が
  /// 面へ届く。
  func testWhileShownEveryPressOnTheFaceGoesToTheConfirmAndAfterClosingItReachesTheFace() throws {
    let hosted = try host()
    let pane = hosted.pane
    func hit(_ point: NSPoint) -> NSView? { pane.hitTest(pane.convert(point, to: pane.superview)) }
    let points = [
      NSPoint(x: pane.bounds.maxX - 20, y: pane.isFlipped ? 10 : pane.bounds.maxY - 10),
      NSPoint(x: 20, y: pane.bounds.midY),
      NSPoint(x: pane.bounds.midX, y: pane.bounds.midY),
    ]

    show(hosted)
    for point in points {
      XCTAssertTrue(hit(point)?.isDescendant(of: pane.confirmHost) == true, "\(point) は確認が受ける")
    }
    hosted.confirm.close(.escape)
    for point in points {
      XCTAssertFalse(hit(point)?.isDescendant(of: pane.confirmHost) ?? true, "閉じた後の \(point) は面へ届く")
    }
  }

  /// 確定は「破棄」の押下だけで行う。幕の押下は何もせず、「キャンセル」は確定せずに閉じる。
  func testOnlyTheConfirmButtonConfirmsAndTheCancelButtonAndTheVeilDoNot() throws {
    let hosted = try host()
    let pane = hosted.pane
    placeOffscreen(hosted.window)
    show(hosted)
    pane.layoutSubtreeIfNeeded()
    // ボタン列は、ダイアログ（左右の中央・上端から editorConfirmTop）の下端から余白の内側に右寄せで並ぶ。
    let dialog = NSHostingView(
      rootView: EditorConfirmDialog(content: content, cancel: {}, confirm: {})
        .frame(width: Theme.Layout.editorConfirmWidth)
        .environment(\.localization, pane.localization))
    let confirmButton = NSHostingView(
      rootView: EditorLargeButton(title: content.confirmTitle, ground: .danger, action: {}))
    let buttonsRight =
      pane.bounds.midX + Theme.Layout.editorConfirmWidth / 2
      - Theme.Layout.editorConfirmPadX
    let cancelRight =
      buttonsRight - confirmButton.fittingSize.width - Theme.Layout.editorConfirmButtonGap
    let buttonsY =
      Theme.Layout.editorConfirmTop + dialog.fittingSize.height
      - Theme.Layout.editorConfirmPadBottom
      - Theme.Layout.editorLargeButton / 2
    func press(x: CGFloat, y: CGFloat) throws {
      try click(pane, at: NSPoint(x: x, y: pane.isFlipped ? y : pane.bounds.maxY - y))
      flush(hosted.window)
    }

    try press(x: 20, y: 20)
    XCTAssertTrue(hosted.confirm.isShown, "幕の押下では閉じない")
    try press(x: cancelRight - 6, y: buttonsY)
    XCTAssertFalse(hosted.confirm.isShown, "「キャンセル」で閉じる")
    XCTAssertEqual(confirmed, 0, "幕と「キャンセル」では確定しない")

    show(hosted)
    try press(x: buttonsRight - 6, y: buttonsY)
    XCTAssertFalse(hosted.confirm.isShown)
    XCTAssertEqual(confirmed, 1, "「破棄」で確定する")
  }

  /// 画面を切り替える・根が変わる（cd）・面が隠れる（⌘E）・フォーカスが確認の外へ移る・面が窓から外れると、確認は確定せずに
  /// 閉じる。フォーカスが外へ移って閉じたときは、フォーカスは移った先に残る。
  func testSwitchingScreensChangingTheRootHidingTheFaceOrTheFocusLeavingClosesWithoutConfirming()
    throws
  {
    let hosted = try host()
    let other = TestScratch.caseDir.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let outsider = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    hosted.tab.group.view.addSubview(outsider)

    show(hosted)
    hosted.tab.group.editor.selectScreen(.changes)
    pumpMain(until: { !hosted.confirm.isShown }, "画面を切り替えると閉じる")

    show(hosted)
    hosted.tab.group.rekey(GitWorktreeRoot.root(of: other.path))
    pumpMain(until: { !hosted.confirm.isShown }, "cd で閉じる")

    show(hosted)
    hosted.tab.group.view.show(.terminal, animated: false)
    XCTAssertFalse(hosted.confirm.isShown, "面が隠れると閉じる")

    hosted.tab.group.view.show(.editor, animated: false)
    show(hosted)
    XCTAssertTrue(hosted.window.makeFirstResponder(outsider))
    nextTurn()
    XCTAssertFalse(hosted.confirm.isShown, "フォーカスが外へ移ると閉じる")
    let responder = try XCTUnwrap(hosted.window.firstResponder as? NSView)
    XCTAssertTrue(responder === outsider || responder.isDescendant(of: outsider), "移った先に残る")

    show(hosted)
    hosted.window.contentView = nil
    XCTAssertFalse(hosted.confirm.isShown, "面が窓から外れると閉じる")
    XCTAssertEqual(confirmed, 0, "どのきっかけでも確定しない")
  }

  /// esc で閉じると、フォーカスは確認を出す前の場所（本体）へ戻る。
  func testEscapeReturnsTheFocusToWhereItWasBeforeTheConfirm() throws {
    let hosted = try host()
    show(hosted)

    try XCTUnwrap(hosted.window.firstResponder).keyDown(with: .key("\u{1b}", []))
    XCTAssertFalse(hosted.confirm.isShown)
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder, "本体へ戻る")
  }
}

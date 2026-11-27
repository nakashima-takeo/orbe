import AppKit
import OrbeEditorCore
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// 面の中の確認（`EditorConfirm`）を本物の面に載せたときの押下・キー・閉じ方・フォーカス・透かし・VoiceOver での扱い。確定の
/// 処理は偽物で、行った回数を記録する。
///
/// 壊れると何が起きるか。「キャンセル」や幕の押下で、取り返しのつかない破棄が走る。行の「破棄」を続けて押した 2 回目が、
/// 出たばかりの確認の「破棄」に当たって破棄が走る。閉じた後も面の上の連打の押下が捨てられ続ける。確認の裏のバー・左の列・
/// 本体が押せて、確認を出したまま別の操作が走る。閉じた後も面が押せない。幕の裏で ⌘B などのエディターのキーが働く。
/// 確認を出した後に cd・画面の切り替え・⌘E が起きても確認が残り、前の根のファイルを捨てる「破棄」が押せる。フォーカスが
/// 外へ移っても確認が残り、幕の裏へ打鍵が届く。esc の後や、フォーカスが窓へ落ちた後に、フォーカスがどこにも無い。⌥ で
/// 透かしても幕が端末を覆う、透かし終えても確認が見えないまま押下とキーを受け続ける。VoiceOver で確認が出たことが分からず、
/// 幕の裏のボタンに届く。
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

  /// 確認のダイアログのボタンの上の点（面の座標）。ボタン列は、ダイアログ（左右の中央・上端から editorConfirmTop）の下端から
  /// 余白の内側に右寄せで並ぶ。
  private func buttonPoints(_ hosted: Hosted) -> (cancel: NSPoint, confirm: NSPoint) {
    let pane = hosted.pane
    pane.layoutSubtreeIfNeeded()
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
    let fromTop =
      Theme.Layout.editorConfirmTop + dialog.fittingSize.height
      - Theme.Layout.editorConfirmPadBottom
      - Theme.Layout.editorLargeButton / 2
    let y = pane.isFlipped ? fromTop : pane.bounds.maxY - fromTop
    return (NSPoint(x: cancelRight - 6, y: y), NSPoint(x: buttonsRight - 6, y: y))
  }

  /// 確定は「破棄」の押下だけで行う。幕の押下は何もせず、「キャンセル」は確定せずに閉じる。
  func testOnlyTheConfirmButtonConfirmsAndTheCancelButtonAndTheVeilDoNot() throws {
    let hosted = try host()
    let pane = hosted.pane
    placeOffscreen(hosted.window)
    show(hosted)
    let buttons = buttonPoints(hosted)
    func press(_ point: NSPoint) throws {
      try click(pane, at: point)
      flush(hosted.window)
    }

    try press(NSPoint(x: 20, y: pane.isFlipped ? 20 : pane.bounds.maxY - 20))
    XCTAssertTrue(hosted.confirm.isShown, "幕の押下では閉じない")
    try press(buttons.cancel)
    XCTAssertFalse(hosted.confirm.isShown, "「キャンセル」で閉じる")
    XCTAssertEqual(confirmed, 0, "幕と「キャンセル」では確定しない")

    show(hosted)
    try press(buttons.confirm)
    XCTAssertFalse(hosted.confirm.isShown)
    XCTAssertEqual(confirmed, 1, "「破棄」で確定する")
  }

  /// 確認が出ている間、連打の 2 回目以降の押下（クリックの数が 2 以上）は「破棄」の上でも確定しない。1 回目の押下なら確定する。
  /// 閉じた後は、面の上の連打の押下が、そのまま届く。
  func testARepeatedPressDoesNotConfirmAndReachesTheFaceAfterClosing() throws {
    let hosted = try host()
    let pane = hosted.pane
    let recorder = PressRecorder(frame: NSRect(x: 100, y: 100, width: 200, height: 100))
    hosted.tab.group.view.addSubview(recorder)
    placeOffscreen(hosted.window)
    show(hosted)
    let buttons = buttonPoints(hosted)

    try click(pane, at: buttons.confirm, count: 2)
    flush(hosted.window)
    XCTAssertTrue(hosted.confirm.isShown, "連打の 2 回目では閉じない")
    XCTAssertEqual(confirmed, 0, "連打の 2 回目では確定しない")
    try click(pane, at: buttons.confirm)
    flush(hosted.window)
    XCTAssertEqual(confirmed, 1, "1 回目の押下で確定する")

    // 本物のダブルクリックと同じく、1 回目の押下から送る。
    try click(recorder, at: NSPoint(x: 100, y: 50))
    try click(recorder, at: NSPoint(x: 100, y: 50), count: 2)
    XCTAssertEqual(recorder.clickCounts, [1, 2], "閉じた後は、面の上の連打の押下が届く")
  }

  /// 確認が出ている間、⌘ つきのエディターのキー（⌘B）は消費して何もせず、窓のキー（⌘E）は窓へ渡す。確認が無ければ、同じ
  /// ⌘B は左の列を開閉する。
  func testWhileShownTheEditorsCommandKeysDoNothingAndTheWindowsKeysPassOn() throws {
    let hosted = try host()
    let pane = hosted.pane
    var commands: [WindowCommand] = []
    hosted.tab.group.onWindowCommand = { commands.append($0) }
    let before = pane.sidebar.isOpen
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("b")))
    let toggled = pane.sidebar.isOpen
    XCTAssertNotEqual(toggled, before, "前提: 確認が無ければ ⌘B は左の列を開閉する")

    show(hosted)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("b")), "⌘B は消費する")
    XCTAssertEqual(pane.sidebar.isOpen, toggled, "確認の間の ⌘B は左の列を開閉しない")
    XCTAssertTrue(hosted.confirm.isShown)
    XCTAssertTrue(pane.performKeyEquivalent(with: .key("e")))
    XCTAssertEqual(commands, [.toggleEditorFace], "⌘E は窓へ渡る")
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

  /// esc で閉じたとき、フォーカスが窓そのものへ落ちて閉じたときは、フォーカスは確認を出す前の場所（本体）へ戻る。
  func testEscapeOrTheFocusFallingToTheWindowReturnsTheFocusToWhereItWas() throws {
    let hosted = try host()
    show(hosted)

    try XCTUnwrap(hosted.window.firstResponder).keyDown(with: .key("\u{1b}", []))
    XCTAssertFalse(hosted.confirm.isShown)
    XCTAssertTrue(hosted.window.firstResponder === hosted.document.surface.responder, "esc で本体へ戻る")

    show(hosted)
    hosted.window.makeFirstResponder(nil)
    nextTurn()
    XCTAssertFalse(hosted.confirm.isShown, "窓へ落ちると閉じる")
    XCTAssertEqual(confirmed, 0)
    XCTAssertTrue(
      hosted.window.firstResponder === hosted.document.surface.responder, "窓へ落ちても本体へ戻る")
  }

  /// ⌥ で透かしている間、確認は閉じずにフォーカスを持ったまま見えなくなり、透かし終えると見える。
  func testPeekingHidesTheConfirmWithoutClosingIt() throws {
    let hosted = try host()
    let pane = hosted.pane
    show(hosted)

    hosted.tab.group.view.show(.peek, animated: false)
    XCTAssertTrue(hosted.confirm.isShown, "透かしでは閉じない")
    XCTAssertTrue(pane.focusIsInConfirm, "フォーカスは確認のまま")
    XCTAssertEqual(pane.confirmHost.alphaValue, 0, "透かしている間は見えない")
    hosted.tab.group.view.show(.editor, animated: false)
    XCTAssertEqual(pane.confirmHost.alphaValue, 1, "透かし終えると見える")
  }

  /// 確認が出ている間、VoiceOver から見た面の子は確認だけで、確認は名前「変更を破棄」のモーダルのダイアログ。閉じると、
  /// 面の子は幕の裏の部品に戻る。
  func testWhileShownTheFaceShowsVoiceOverOnlyTheConfirmAsAModalDialog() throws {
    let hosted = try host()
    let pane = hosted.pane
    let host = pane.confirmHost
    show(hosted)

    let children = try XCTUnwrap(pane.accessibilityChildren() as? [NSView])
    XCTAssertEqual(children.count, 1)
    XCTAssertTrue(children.first === host, "面の子は確認だけ")
    XCTAssertTrue(host.isAccessibilityElement())
    XCTAssertEqual(host.accessibilitySubrole(), .dialog)
    XCTAssertEqual(host.accessibilityLabel(), content.label)
    XCTAssertTrue(host.isAccessibilityModal())

    hosted.confirm.close(.escape)
    let after = pane.accessibilityChildren() ?? []
    XCTAssertFalse(after.isEmpty)
    XCTAssertFalse(after.contains { ($0 as? NSView) === host }, "閉じると、子は幕の裏の部品に戻る")
  }
}

/// 押下を受けた回数（クリックの数）を記録する view。
private final class PressRecorder: NSView {
  private(set) var clickCounts: [Int] = []

  override func mouseDown(with event: NSEvent) { clickCounts.append(event.clickCount) }
}

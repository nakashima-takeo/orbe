import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 読むだけの面（PR の diff）——本文を変える入口がどれも本文を変えず、メニューでも無効になり、読む操作（選択・コピー・
/// スクロール）は効き、載せる側の差し替えは undo に溜まらない。壊れると、読むだけの diff に打った字・貼った字・落とした字
/// が入り、⌘Z で載せる側が差し替える前の中身へ戻る。
@MainActor
final class SurfaceReadOnlyTests: EngineTestCase {
  private let source = "let a = 1\nlet b = 2\n"

  private func openReadOnly() throws -> Opened {
    let opened = try open(source)
    _ = host(opened)
    opened.surface.isEditable = false
    return opened
  }

  /// 打鍵・削除・改行・カット・ペースト・ヤンク・大小文字・サービスの書き込み・IME の呼び出しは本文を変えず、undo も
  /// 積まない。選択とコピーと移動は効く。
  func testEditingEntrancesLeaveTheTextAlone() throws {
    let opened = try openReadOnly()
    let view = opened.surface.textView
    let board = privatePasteboard(opened)
    opened.surface.selectedRange = NSRange(location: 4, length: 1)
    type(opened, "xyz")
    try key(opened, "\r")
    view.deleteBackward(nil)
    view.insertNewline(nil)
    view.uppercaseWord(nil)
    view.yank(nil)
    view.cut(nil)
    board.clearContents()
    board.setString("pasted", forType: .string)
    view.paste(nil)
    XCTAssertFalse(view.readSelection(from: board))
    IMECall.mark("あ").send(to: view)
    IMECall.insert("い").send(to: view)
    XCTAssertEqual(text(opened.document), source)
    XCTAssertFalse(view.hasMarkedText())
    XCTAssertFalse(opened.surface.editor.undoManager.canUndo, "undo を積まない")
    view.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "a", "選択は残り、写せる")
    view.moveDown(nil)
    XCTAssertEqual(opened.surface.caretLocation, 15, "移動は効く")
    view.selectAll(nil)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 20))
  }

  /// 読むだけの本文は入力の文脈を返さない（IME が変換を始めない）。編集できる面に戻すと返す。
  func testReadOnlyBodyHasNoInputContext() throws {
    let opened = try openReadOnly()
    XCTAssertNil(opened.surface.textView.inputContext)
    opened.surface.isEditable = true
    XCTAssertNotNil(opened.surface.textView.inputContext)
  }

  /// 編集の項目（取り消す・やり直す・カット・ペースト・削除・大小文字）はメニューで無効、コピーと全部を選ぶは有効。編集した
  /// 後で読むだけにしても、取り消すは効かない。
  func testEditMenuItemsAreDisabled() throws {
    let opened = try open(source)
    _ = host(opened)
    let board = privatePasteboard(opened)
    board.setString("y", forType: .string)
    type(opened, "z")
    let view = opened.surface.textView
    func enabled(_ action: Selector) -> Bool {
      view.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
    XCTAssertTrue(enabled(#selector(MetalTextView.undo(_:))), "前提: 編集できる面で取り消せる")
    opened.surface.isEditable = false
    for action in [
      #selector(MetalTextView.undo(_:)), #selector(MetalTextView.redo(_:)),
      #selector(MetalTextView.cut(_:)), #selector(MetalTextView.paste(_:)),
      #selector(MetalTextView.pasteAsPlainText(_:)), #selector(MetalTextView.delete(_:)),
      #selector(MetalTextView.uppercaseWord(_:)),
    ] {
      XCTAssertFalse(enabled(action), "\(action) は無効")
    }
    XCTAssertTrue(enabled(#selector(MetalTextView.copy(_:))))
    XCTAssertTrue(enabled(#selector(MetalTextView.selectAll(_:))))
    view.undo(nil)
    XCTAssertEqual(text(opened.document), "z" + source, "取り消すは効かない")
    XCTAssertNil(
      view.validRequestor(forSendType: nil, returnType: .string), "サービスから字を受けない")
  }

  /// 載せる側の丸ごとの置き換えは通り、undo に載らない——何度差し替えても取り消せるものが溜まらない。
  func testReplacingTheWholeTextDoesNotPileUndo() throws {
    let opened = try openReadOnly()
    opened.surface.replaceAll(with: "let c = 3\n")
    opened.surface.replaceAll(with: "let d = 4\n")
    XCTAssertEqual(text(opened.document), "let d = 4\n")
    XCTAssertFalse(opened.surface.editor.undoManager.canUndo)
  }

  /// 本文へ落とした字は入らない。Finder のファイルは載せる側に開かせる。
  func testDropsInsertNothingButFilesStillOpen() throws {
    let opened = try openReadOnly()
    let hostSide = RecordingHost()
    opened.surface.host = hostSide
    let view = opened.surface.textView
    let at = view.convert(point(opened, row: 0, column: 3), to: nil)
    let board = privatePasteboard(opened)
    board.clearContents()
    board.setString("x", forType: .string)
    XCTAssertFalse(view.performDragOperation(FakeDraggingInfo(at: at, pasteboard: board)))
    let file = URL(fileURLWithPath: "/tmp/a.swift")
    board.clearContents()
    board.writeObjects([file as NSURL])
    XCTAssertTrue(view.performDragOperation(FakeDraggingInfo(at: at, pasteboard: board)))
    XCTAssertEqual(hostSide.openedFiles, [[file]])
    XCTAssertEqual(text(opened.document), source)
  }
}

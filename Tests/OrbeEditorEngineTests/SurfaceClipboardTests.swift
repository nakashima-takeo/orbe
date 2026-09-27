import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のコピー・カット・ペースト（VS Code の既定）・サービス・右クリック・本文のドラッグ＆ドロップ。どれも専用の
/// ペーストボードで確かめる。壊れると空の選択の ⌘C が何も写さない・行が行の途中に貼られる・CRLF の文書に LF が混ざる・
/// 移動が 2 回の undo になる・右クリックで選択が消える。
@MainActor
final class SurfaceClipboardTests: EngineTestCase {
  /// 選択が空の ⌘C / ⌘X は行を改行込みで写し（改行の無い最終行は文書の改行を足す）、行ごと写した印を付ける。⌘X は行を
  /// 消す（最終行なら前の行の改行から）。
  func testCopyAndCutWithoutSelectionTakeTheWholeLine() throws {
    let opened = try open("one\ntwo\nlast")
    _ = host(opened)
    let board = privatePasteboard(opened)
    let view = opened.surface.textView
    opened.surface.selectedRange = NSRange(location: 5, length: 0)
    view.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "two\n")
    XCTAssertNotNil(board.availableType(from: [MetalTextView.entireLineType]))
    opened.surface.selectedRange = NSRange(location: 9, length: 0)
    view.cut(nil)
    XCTAssertEqual(board.string(forType: .string), "last\n", "改行の無い最終行は文書の改行を足す")
    XCTAssertEqual(text(opened.document), "one\ntwo", "最終行は前の行の改行から消す")
    opened.surface.selectedRange = NSRange(location: 1, length: 0)
    view.cut(nil)
    XCTAssertEqual(text(opened.document), "two")
    opened.surface.selectedRange = NSRange(location: 0, length: 2)
    view.copy(nil)
    XCTAssertEqual(board.string(forType: .string), "tw")
    XCTAssertNil(board.availableType(from: [MetalTextView.entireLineType]), "選択を写したら印は付けない")
  }

  /// 行ごと写した文字列を選択なしで貼ると、キャレットの行の上に行として入り、キャレットは同じ字のまま 1 行下がる。選択が
  /// あれば置き換える。貼ると前後で undo が区切れる。
  func testPastingAWholeLineGoesAboveTheCaretLine() throws {
    let opened = try open("one\ntwo\n")
    _ = host(opened)
    privatePasteboard(opened)
    let view = opened.surface.textView
    opened.surface.selectedRange = NSRange(location: 1, length: 0)
    view.copy(nil)
    opened.surface.selectedRange = NSRange(location: 6, length: 0)
    type(opened, "!")
    view.paste(nil)
    XCTAssertEqual(text(opened.document), "one\none\ntw!o\n")
    XCTAssertEqual(opened.surface.caretLocation, 11, "同じ字のまま 1 行下がる")
    let undo = try XCTUnwrap(view.undoManager)
    undo.undo()
    XCTAssertEqual(text(opened.document), "one\ntw!o\n", "貼る前で区切る")
    opened.surface.selectedRange = NSRange(location: 4, length: 2)
    view.paste(nil)
    XCTAssertEqual(text(opened.document), "one\none\n!o\n", "選択があれば置き換える")
  }

  /// 色の付く文書で選択 1 つなら、構文色付きの HTML も載せる（VS Code と同じ形）。
  func testCopyCarriesColoredHTML() throws {
    let opened = try open("let a = 1\n")
    _ = host(opened)
    let board = privatePasteboard(opened)
    opened.surface.selectedRange = NSRange(location: 0, length: 9)
    opened.surface.textView.copy(nil)
    let html = try XCTUnwrap(board.string(forType: .html))
    XCTAssertTrue(html.hasPrefix("<div style=\"color: #cccccc;background-color: #1f1f1f;"), html)
    XCTAssertTrue(html.contains("white-space: pre;"))
    XCTAssertTrue(html.contains("<span style=\"color: #579cd6;\">let</span>"), html)
    let plain = try open("plain words\n", name: "a.txt")
    _ = host(plain)
    let plainBoard = privatePasteboard(plain)
    plain.surface.selectedRange = NSRange(location: 0, length: 5)
    plain.surface.textView.copy(nil)
    XCTAssertNil(plainBoard.string(forType: .html), "色の無い文書は平文だけ")
  }

  /// 貼る文字列と Enter の改行は、文書の作法（CRLF）に揃う。
  func testPasteAndEnterFollowTheDocumentLineBreak() throws {
    let opened = try open("a\r\nb\r\n")
    _ = host(opened)
    let board = privatePasteboard(opened)
    board.declareTypes([.string], owner: nil)
    board.setString("x\ny\rz", forType: .string)
    opened.surface.selectedRange = NSRange(location: 1, length: 0)
    opened.surface.textView.paste(nil)
    XCTAssertEqual(text(opened.document), "ax\r\ny\r\nz\r\nb\r\n")
    opened.surface.perform(.newline(indents: true))
    XCTAssertEqual(text(opened.document), "ax\r\ny\r\nz\r\n\r\nb\r\n")
  }

  /// Finder でコピーしたファイルを貼ると、載せる側が決めたパスの文字列が入る。
  func testPastingFinderFilesInsertsTheirPaths() throws {
    let opened = try open("\n")
    _ = host(opened)
    let board = privatePasteboard(opened)
    let hostSide = RecordingHost()
    opened.surface.host = hostSide
    board.clearContents()
    board.writeObjects([
      URL(fileURLWithPath: "/tmp/a.txt") as NSURL, URL(fileURLWithPath: "/tmp/b c.md") as NSURL,
    ])
    opened.surface.textView.paste(nil)
    XCTAssertEqual(text(opened.document), "a.txt b c.md\n")
  }

  /// コピー・カットはいつも有効、ペーストは平文かファイルがあるときだけ。
  func testEditMenuValidation() throws {
    let opened = try open("x\n")
    let board = privatePasteboard(opened)
    let view = opened.surface.textView
    func enabled(_ action: Selector) -> Bool {
      view.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
    board.clearContents()
    XCTAssertTrue(enabled(#selector(MetalTextView.copy(_:))))
    XCTAssertTrue(enabled(#selector(MetalTextView.cut(_:))))
    XCTAssertFalse(enabled(#selector(MetalTextView.paste(_:))))
    board.setString("y", forType: .string)
    XCTAssertTrue(enabled(#selector(MetalTextView.paste(_:))))
  }

  /// サービスは選択の平文を受け取り、返した平文で選択を置き換える。
  func testServicesReadAndWriteTheSelection() throws {
    let opened = try open("hello world\n")
    _ = host(opened)
    let view = opened.surface.textView
    XCTAssertNil(view.validRequestor(forSendType: .string, returnType: nil), "選択が無ければ送れない")
    opened.surface.selectedRange = NSRange(location: 6, length: 5)
    XCTAssertTrue(
      view.validRequestor(forSendType: .string, returnType: .string) as AnyObject === view)
    let board = NSPasteboard(name: NSPasteboard.Name("dev.orbe.test.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    XCTAssertTrue(view.writeSelection(to: board, types: [.string]))
    XCTAssertEqual(board.string(forType: .string), "world")
    board.declareTypes([.string], owner: nil)
    board.setString("WORLD", forType: .string)
    XCTAssertTrue(view.readSelection(from: board))
    XCTAssertEqual(text(opened.document), "hello WORLD\n")
  }

  /// 右クリックは先に変換を確定し、選択の外ならキャレットをそこへ動かし、選択の中なら選択を保つ。中身は載せる側が組み、
  /// Writing Tools を足させない。
  func testContextMenuKeepsTheSelectionInsideAndMovesTheCaretOutside() throws {
    let opened = try open("abc def\n")
    let window = host(opened)
    fakeInputMethod(opened)
    let hostSide = RecordingHost()
    opened.surface.host = hostSide
    let view = opened.surface.textView
    func event(column: CGFloat) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .rightMouseDown,
          location: view.convert(point(opened, row: 0, column: column), to: nil),
          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
          eventNumber: 0, clickCount: 1, pressure: 1))
    }
    opened.surface.selectedRange = NSRange(location: 4, length: 3)
    let menu = try XCTUnwrap(view.menu(for: try event(column: 5)))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 4, length: 3), "選択の中なら保つ")
    XCTAssertEqual(menu.items.map(\.title), ["Copy"])
    if #available(macOS 15.2, *) { XCTAssertFalse(menu.automaticallyInsertsWritingToolsItems) }
    replay([.mark("x")], on: opened)
    _ = view.menu(for: try event(column: 1))
    XCTAssertFalse(view.hasMarkedText(), "先に確定する")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 1, length: 0), "選択の外ならキャレットを動かす")
    XCTAssertEqual(hostSide.menus, 2)
  }

  /// 同じ面の中の移動は削除と挿入を 1 つの束で渡し、1 回の undo で戻り、落とした文字列が選ばれる。
  func testMovingTextIsOneUndoAndSelectsTheDroppedText() throws {
    let opened = try open("abc def\n")
    _ = host(opened)
    opened.surface.perform(.drop("abc", at: 7, moving: NSRange(location: 0, length: 3)))
    XCTAssertEqual(text(opened.document), " defabc\n")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 4, length: 3))
    try XCTUnwrap(opened.surface.textView.undoManager).undo()
    XCTAssertEqual(text(opened.document), "abc def\n")
    opened.surface.perform(.drop("x\ny", at: 0, moving: nil))
    XCTAssertEqual(text(opened.document), "x\nyabc def\n")
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 3))
  }

  /// 選択の上を押して動かさずに離せば、その位置にキャレットを置く（動かせば文字のドラッグが始まる）。
  func testClickingOnTheSelectionPlacesTheCaretOnRelease() throws {
    let opened = try open("abc def\n")
    _ = host(opened)
    opened.surface.selectedRange = NSRange(location: 0, length: 7)
    try mouse(opened, .leftMouseDown, at: point(opened, row: 0, column: 2))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 0, length: 7), "押しただけでは選択を保つ")
    try mouse(opened, .leftMouseUp, at: point(opened, row: 0, column: 2))
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 2, length: 0))
  }

  /// 落とす位置の印は本文と同じ 1 コマに、キャレットの色の点線で描く。
  func testDropIndicatorIsDrawnInTheFrame() throws {
    let opened = try open("abc\n")
    _ = host(opened, size: CGSize(width: 300, height: 60))
    opened.surface.write { $0.drop = 2 }
    let image = try XCTUnwrap(opened.surface.snapshot())
    let config = opened.surface.config
    let x = Int(((config.columnWidth(lineCount: 2) + 2 * config.cell) * 2).rounded())
    let top = Int((config.topInset * 2).rounded())
    XCTAssertEqual(pixel(image, x: x, y: top + 1), [255, 255, 255, 255], "点")
    XCTAssertEqual(pixel(image, x: x, y: top + 5)[3], 0, "間")
  }
}

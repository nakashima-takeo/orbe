import AppKit
import XCTest

@testable import Orbe
@testable import OrbeEditorCore

/// 本物のテキストエンジンと文書の噛み合わせ——打鍵が文書へ届き、続けた打鍵が ⌘Z 1 回でまとめて
/// 戻り、未保存は本文の比較ではなく「保存の後に編集があったか」。fake の面では見えない部分だけを
/// ここが持つ（色付けの中身は `OrbeEditorCoreTests` が fake の面で見る）。
///
/// 壊れると何が起きるか。⌘Z が 1 文字ずつしか戻らないと打ち直しが苦行になる。未保存の判定が本文の
/// 比較になると、⌘Z で戻した文書が未保存に見えなくなり ⌘S しても書かれない。色付けが本文を書き換えて
/// いれば、ファイルを開いただけで全部が未保存になる。
@MainActor
final class EditorTextSurfaceTests: OrbeTestCase {
  /// queries はテスト実行体の隣（`.build/<config>`）の資源バンドルから解く——ハーネスが
  /// `BundledResources.root` を空 dir へ張り替えるので、色を見るには明示注入が要る。
  private var surfaces: EditorSurfaces {
    EditorSurfaces(queriesRoot: Bundle(for: Self.self).bundleURL.deletingLastPathComponent())
  }

  private func file(_ name: String, _ text: String) throws -> URL {
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  /// 文書を開き、そのテキスト面を first responder にした窓を返す（打鍵の受け手にする）。
  private func opened(_ url: URL) throws -> (EditorDocument, NSWindow) {
    let session = EditorSession(surfaces: surfaces)
    let document = try session.open(url)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = document.surface.view
    document.surface.view.frame = try XCTUnwrap(window.contentView).bounds
    window.makeFirstResponder(document.surface.responder)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    return (document, window)
  }

  private func type(_ text: String, into document: EditorDocument) {
    for character in text {
      document.surface.responder.keyDown(with: .key(String(character), []))
    }
  }

  /// 打った文字がそのまま本文になって文書へ届き、続けて打った打鍵は ⌘Z 1 回でまとめて本文ごと戻る
  /// （色が rendering attribute でなく本文側の属性なら、undo は色の適用を取り消して本文は戻らない）。
  func testTypingReachesTheDocumentAndUndoRestoresTheTypedRun() throws {
    let (document, _) = try opened(try file("a.swift", "let a = 1\n"))
    XCTAssertNotNil(document.language)

    type("xy", into: document)
    XCTAssertEqual(document.surface.text, "xylet a = 1\n")
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(document.lineIndex, LineIndex(text: document.surface.text), "索引が本物の編集に追従する")

    document.surface.responder.undoManager?.undo()
    XCTAssertEqual(document.surface.text, "let a = 1\n", "続けた打鍵がまとめて本文ごと戻る")
  }

  /// 未保存は「保存の後に編集があったか」——⌘Z で編集前の本文へ戻しても未保存は消えず、消すのは保存だけ。
  func testUnsavedSurvivesUndoingBackToTheUnchangedText() throws {
    let url = try file("b.txt", "abc")
    let (document, _) = try opened(url)
    XCTAssertFalse(document.isDirty)

    type("d", into: document)
    XCTAssertTrue(document.isDirty)
    document.surface.responder.undoManager?.undo()
    XCTAssertEqual(document.surface.text, "abc", "開いたときの本文へ戻った")
    XCTAssertTrue(document.isDirty, "本文が同じでも未保存は残る（本文の比較ではない）")

    try document.save()
    XCTAssertFalse(document.isDirty, "未保存を消すのは保存だけ")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "abc")
  }

  /// 保存は undo の区切り——打つ → 保存 → 打つ → ⌘Z で、戻るのは保存の後の打鍵だけ
  /// （区切らなければ挿入位置が繋がる限り 1 つのまとまりで、保存前の打鍵まで一緒に戻る）。
  func testSavingMarksAnUndoBoundary() throws {
    let url = try file("d.txt", "")
    let (document, _) = try opened(url)

    type("ab", into: document)
    try document.save()
    type("cd", into: document)
    XCTAssertEqual(document.surface.text, "abcd")

    document.surface.responder.undoManager?.undo()
    XCTAssertEqual(document.surface.text, "ab", "保存の後の打鍵だけが戻る")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ab", "保存した内容はそのまま")

    document.surface.responder.undoManager?.undo()
    XCTAssertEqual(document.surface.text, "", "もう 1 回で保存前の打鍵が戻る")
  }

  /// 本文の丸ごと置き換えは、通常の編集と同じく文書へ 1 回で届き（索引が追従する）、⌘Z で丸ごと戻る。
  /// 置き換えの後に打った打鍵は置き換えと一緒には戻らない（区切りになる）。
  func testReplaceAllReachesTheDocumentOnceAndUndoesAsOneStep() throws {
    let (document, _) = try opened(try file("e.swift", "let a = 1\n"))
    type("x", into: document)
    var edits: [TextEdit] = []
    let spy = SurfaceSpy(inner: document) { edits.append($0) }
    document.surface.delegate = spy

    document.surface.replaceAll(with: "struct S {}\nlet b = 2\n")
    XCTAssertEqual(document.surface.text, "struct S {}\nlet b = 2\n")
    XCTAssertEqual(
      edits, [TextEdit(range: NSRange(location: 0, length: 11), replacementLength: 22)], "全体の置換 1 回"
    )
    XCTAssertEqual(document.lineIndex, LineIndex(text: document.surface.text))

    document.surface.markUndoBoundary()
    type("y", into: document)
    document.surface.responder.undoManager?.undo()
    XCTAssertEqual(document.surface.text, "struct S {}\nlet b = 2\n", "置き換えの後の打鍵だけ戻る")
    document.surface.responder.undoManager?.undo()
    XCTAssertEqual(document.surface.text, "xlet a = 1\n", "置き換えが丸ごと戻る")
    withExtendedLifetime(spy) {}
  }

  /// 変換中（marked text）に本文が丸ごと差し替わっても、変換セッションは畳まれていて次の変換操作が古い
  /// 本文の位置を指さない。⌘S は `keyDown` を経ずに解決されるので、変換途中でも保存が通って未保存が消え、
  /// その直後の外部変更で差し替えが走りうる（畳まないと本文が短くなった側で落ち、長い側で無関係な位置が削れる）。
  func testReplaceAllEndsAnInputMethodCompositionFirst() throws {
    let (document, _) = try opened(try file("f.txt", "let a = 1\n"))
    let client = try XCTUnwrap(document.surface.responder as? NSTextInputClient)
    document.surface.responder.perform(#selector(NSResponder.moveToEndOfDocument(_:)), with: nil)
    client.setMarkedText(
      "かん", selectedRange: NSRange(location: 0, length: 2),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(client.hasMarkedText())
    XCTAssertEqual(document.surface.text, "let a = 1\nかん")

    document.surface.replaceAll(with: "short\n")
    XCTAssertFalse(client.hasMarkedText(), "置き換えの前に変換を畳む")
    // 畳めていなければ次の変換操作でプロセスごと落ち、残りのテストの結果が消える。
    guard !client.hasMarkedText() else { return }
    XCTAssertEqual(document.surface.text, "short\n")

    client.setMarkedText(
      "き", selectedRange: NSRange(location: 0, length: 1),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    client.insertText("き", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(document.surface.text, "short\nき", "次の変換操作は新しい本文の末尾に付く")
  }

  /// 置き換え後の選択は解け、キャレットは同じオフセットへ戻る（契約は `TextSurface` の doc と code の
  /// 「テキストエンジンの境界」）。本文が短くなる側は TextKit の丸めと結果が一致するので、ここでは clamp の
  /// 有無を判別できない。
  func testReplaceAllRestoresTheCaretOffsetAndCollapsesTheSelection() throws {
    let (document, _) = try opened(try file("g.txt", "0123456789\n"))
    let client = try XCTUnwrap(document.surface.responder as? NSTextInputClient)
    document.surface.responder.perform(#selector(NSResponder.moveToEndOfDocument(_:)), with: nil)
    document.surface.responder.perform(
      #selector(NSResponder.moveLeftAndModifySelection(_:)), with: nil)
    XCTAssertEqual(client.selectedRange(), NSRange(location: 10, length: 1), "前提: 末尾側に選択がある")

    document.surface.replaceAll(with: "01234\n")
    XCTAssertEqual(
      client.selectedRange(), NSRange(location: 6, length: 0), "選択は解け、末尾に収まる（TextKit の丸めと一致）")

    document.surface.replaceAll(with: "0123456789abc\n")
    XCTAssertEqual(client.selectedRange(), NSRange(location: 6, length: 0), "収まるなら同じオフセット")
  }

  /// 文書の前に割り込んで編集を記録する delegate（文書へも流す）。
  private final class SurfaceSpy: TextSurfaceDelegate {
    let inner: EditorDocument
    let record: (TextEdit) -> Void
    init(inner: EditorDocument, record: @escaping (TextEdit) -> Void) {
      self.inner = inner
      self.record = record
    }
    func surface(_ surface: any TextSurface, didChange edit: TextEdit) {
      record(edit)
      inner.surface(surface, didChange: edit)
    }
    func surface(_ surface: any TextSurface, focusDidChange focused: Bool) {
      inner.surface(surface, focusDidChange: focused)
    }
    func surfaceDidLayoutViewport(_ surface: any TextSurface) {
      inner.surfaceDidLayoutViewport(surface)
    }
    func surfaceDidScroll(_ surface: any TextSurface) {
      inner.surfaceDidScroll(surface)
    }
    func surfaceDidChangeSelection(_ surface: any TextSurface) {
      inner.surfaceDidChangeSelection(surface)
    }
  }

  /// 面は器の上端の余白を除いた高さに収まり、器の高さが変わっても収まり続ける（余白の分だけ長いと
  /// 最下行が常に切れ、余白の帯が素地として露出する）。
  func testSurfaceFitsTheContainerBelowTheTopInset() throws {
    let surface = surfaces.make("x")
    let container = surface.view
    let inset = EditorStyle.make().topInset
    container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    container.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(container.subviews.first)
    XCTAssertEqual(scroll.frame, NSRect(x: 0, y: inset, width: 800, height: 600 - inset))

    container.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
    container.layoutSubtreeIfNeeded()
    XCTAssertEqual(scroll.frame, NSRect(x: 0, y: inset, width: 500, height: 300 - inset))
  }

  /// 色付けは本文を書き換えないので、色の付いた文書を開いただけでは未保存にならない
  /// （面の本文を編集して色を置いていれば、開いた瞬間に全ファイルが未保存になる）。
  func testOpeningAColoredDocumentIsNotDirty() throws {
    let url = try file("c.swift", "struct S {\n  let a = 1\n}\n")
    let session = EditorSession(surfaces: surfaces)
    let document = try session.open(url)

    let language = try XCTUnwrap(document.language)
    XCTAssertNotNil(
      surfaces.registry.configuration(for: language), "色付けが走る前提（queries が解けている）")
    XCTAssertFalse(document.isDirty)
    XCTAssertFalse(session.hasUnsavedChanges)
  }
}

/// 俯瞰と検索がエンジンに求める契約——viewport は実際に layout された行の矩形から本文の言葉で出て、
/// `scrollToCenter` はその行を clip の中央へ、選択は読み書きでき変化が delegate へ届く。
extension EditorTextSurfaceTests {
  fileprivate struct Tall {
    let document: EditorDocument
    let window: NSWindow
    let scroll: NSScrollView
  }

  fileprivate func openedTall(_ lines: Int) throws -> Tall {
    let session = EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
    let text = (1...lines).map { "line \($0)\n" }.joined()
    let url = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent(
      "tall-\(UUID().uuidString).txt")
    try Data(text.utf8).write(to: url)
    let document = try session.open(url)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = document.surface.view
    document.surface.view.frame = try XCTUnwrap(window.contentView).bounds
    document.surface.view.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let scroll = try XCTUnwrap(document.surface.view.subviews.first as? NSScrollView)
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "viewport が出る")
    withExtendedLifetime(session) {}
    return Tall(document: document, window: window, scroll: scroll)
  }

  func testViewportReportsTheTopLineAndItsHiddenFraction() throws {
    let tall = try openedTall(100)
    let (document, scroll) = (tall.document, tall.scroll)
    let lineHeight = EditorStyle.make().lineHeight
    let inset = EditorStyle.make().topInset
    var viewport = document.surface.viewport
    XCTAssertEqual(viewport.firstVisible, 0)
    XCTAssertEqual(viewport.hiddenFraction, 0)
    XCTAssertEqual(viewport.visibleLines, (200 - inset) / lineHeight, accuracy: 0.01, "可視矩形の行数（小数）")

    scroll.contentView.scroll(to: NSPoint(x: 0, y: 49 * lineHeight + lineHeight / 2))
    scroll.reflectScrolledClipView(scroll.contentView)
    pumpMain(until: { document.surface.viewport.firstVisible > 0 }, "viewport が動く")
    viewport = document.surface.viewport
    XCTAssertEqual(viewport.firstVisible, document.lineIndex.start(ofRow: 49), "先頭に見えている行の行頭")
    XCTAssertEqual(viewport.hiddenFraction, 0.5, accuracy: 0.01, "半分隠れている")
  }

  func testScrollToCenterPutsTheLineInTheMiddleOfTheClipAndClampsAtTheEnds() throws {
    let document = try openedTall(100).document
    let visible = document.surface.viewport.visibleLines
    var scrolled = 0
    document.onViewportChange = { scrolled += 1 }
    document.surface.scrollToCenter(document.lineIndex.start(ofRow: 60))
    pumpMain(until: { document.surface.viewport.firstVisible > 0 }, "動く")
    let first =
      CGFloat(document.lineIndex.point(at: document.surface.viewport.firstVisible).row)
      + document.surface.viewport.hiddenFraction
    XCTAssertEqual(first, 60.5 - visible / 2, accuracy: 0.6, "行 60 の中心が clip の中央")
    XCTAssertGreaterThan(scrolled, 0, "viewport の変化が届く")

    document.surface.scrollToCenter(0)
    pumpMain(until: { document.surface.viewport.firstVisible == 0 }, "先頭で止まる")
    XCTAssertEqual(document.surface.viewport.hiddenFraction, 0)
    document.surface.scrollToCenter(document.lineIndex.start(ofRow: 99))
    pumpMain(
      until: {
        document.lineIndex.point(at: document.surface.viewport.firstVisible).row >= 99
          - Int(visible)
      },
      "末尾で止まる")
  }

  func testSelectedRangeIsReadWriteAndChangesReachTheDocument() throws {
    let tall = try openedTall(3)
    let (document, window) = (tall.document, tall.window)
    var changes = 0
    document.onSelectionChange = { changes += 1 }
    document.surface.selectedRange = NSRange(location: 7, length: 4)
    XCTAssertEqual(document.surface.selectedRange, NSRange(location: 7, length: 4))
    pumpMain(until: { changes > 0 }, "選択の変化が届く")
    XCTAssertEqual(document.surface.viewport.firstVisible, 0, "置くだけで見せない")
    window.makeFirstResponder(document.surface.responder)
    let before = changes
    document.surface.responder.perform(#selector(NSResponder.moveToEndOfDocument(_:)), with: nil)
    pumpMain(until: { changes > before }, "人の操作でも届く")
  }
}

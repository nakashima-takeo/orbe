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

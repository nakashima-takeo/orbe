import AppKit
import OrbeEditorCore
import STTextView
import XCTest

@testable import Orbe

/// 文書の写し（ロープ）が本物のテキスト面の本文を追うこと。面の本文のすべての変更は、置換後の文字列つきの編集の通知で
/// 文書へ届く——通知が 1 つでも漏れれば、以後の色・印・検索・保存が全部ずれる。
extension EditorTextSurfaceTests {
  /// 乱択の操作（打鍵・改行・削除・選択を置き換える打鍵・複数キャレットの打鍵・大文字化・undo / redo・IME の変換と
  /// 確定・丸ごと置き換え）の後も、文書の写しは面の本文と UTF-16 の単位で同じ。本文に絵文字（サロゲートの対）と CRLF を
  /// 含め、選択がサロゲートの対を割る置き換えと、その undo も通る（種 5・10 はその経路で写しがずれた）。
  func testTheDocumentCopyFollowsTheSurfaceThroughRandomOperations() throws {
    for seed: UInt64 in [5, 10, 17] {
      let source = (1...40).map {
        "let value\($0) = compute(\($0)) // 注😀 \($0)\($0 % 3 == 0 ? "\r\n" : "\n")"
      }.joined()
      let (document, _) = try opened(try file("copy\(seed).swift", source))
      let generator = Lehmer(seed: seed)
      let operations = try randomOperations(document, generator)
      for step in 0..<400 {
        let (name, operation) = operations[generator.next(below: operations.count)]
        operation()
        if step % 75 == 74 {
          document.surface.replaceAll(
            with: document.text.string.replacingOccurrences(of: "let", with: "var"))
        }
        guard Array(document.text.contiguousUnits()) == engineUnits(document) else {
          XCTFail("種 \(seed) の \(step) 回目の\(name)で写しが面の本文とずれた")
          break
        }
      }
    }
  }

  /// サロゲートの対の片方だけを選んで打ち、undo すると、面の本文は元の絵文字に戻る。写しも同じ単位に戻り、保存したファイルは
  /// 元のバイト列のまま（片割れを置換の文字列に載せられず、写しが U+FFFD 2 つに化けて保存で絵文字が壊れていた）。
  func testUndoingAnEditThatSplitASurrogatePairRestoresTheCopyAndTheFile() throws {
    let url = try file("split.swift", "a😀b\n")
    let (document, _) = try opened(url)
    let responder = document.surface.responder
    document.surface.selectedRange = NSRange(location: 1, length: 1)
    responder.insertText("x")
    XCTAssertEqual(Array(document.text.contiguousUnits()), engineUnits(document), "片割れが残った本文")
    responder.undoManager?.undo()
    XCTAssertEqual(engineUnits(document), Array("a😀b\n".utf16), "前提: 面は元に戻る")
    XCTAssertEqual(Array(document.text.contiguousUnits()), engineUnits(document), "写しも元に戻る")
    try document.save(force: true)
    XCTAssertEqual(try Data(contentsOf: url), Data("a😀b\n".utf8), "保存したファイルは壊れない")
  }

  /// 面を本文の変わる操作で動かす手（名前と操作）。位置は `generator` で選ぶ。
  private func randomOperations(_ document: EditorDocument, _ generator: Lehmer) throws
    -> [(String, () -> Void)]
  {
    let responder = document.surface.responder
    let view = try XCTUnwrap(responder as? STTextView)
    let client = try XCTUnwrap(responder as? NSTextInputClient)
    func anywhere() -> Int { generator.next(below: document.text.length + 1) }
    return [
      ("打鍵", { responder.keyDown(with: .key("x", [])) }),
      ("改行", { responder.keyDown(with: .key("\n", [])) }),
      ("削除", { responder.deleteBackward(nil) }),
      (
        "選択を置き換える打鍵",
        {
          let start = anywhere()
          document.surface.selectedRange = NSRange(
            location: start, length: min(7, document.text.length - start))
          responder.insertText("😀q")
        }
      ),
      (
        "複数キャレットの打鍵",
        {
          let manager = view.textContentManager
          let locations = Set((0..<3).map { _ in generator.next(below: document.text.length) })
            .compactMap { manager.location(manager.documentRange.location, offsetBy: $0) }
          guard !locations.isEmpty else { return }
          view.textLayoutManager.textSelections = locations.map {
            NSTextSelection($0, affinity: .downstream)
          }
          responder.insertText("ab")
        }
      ),
      (
        "大文字化",
        {
          responder.perform(#selector(NSResponder.uppercaseWord(_:)), with: nil)
          // 上流（STTextView 2.4.1）は語の外で大文字化すると選択を空にし、次の打鍵が挿す位置を失う。キャレットを戻す。
          if view.textLayoutManager.textSelections.isEmpty {
            document.surface.selectedRange = NSRange(location: 0, length: 0)
          }
        }
      ),
      ("undo", { responder.undoManager?.undo() }),
      ("redo", { responder.undoManager?.redo() }),
      (
        "IME の変換と確定",
        {
          let none = NSRange(location: NSNotFound, length: 0)
          client.setMarkedText(
            "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
          client.setMarkedText(
            "かん", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
          client.insertText("漢", replacementRange: none)
        }
      ),
      ("キャレットを動かす", { document.surface.selectedRange = NSRange(location: anywhere(), length: 0) }),
    ]
  }
}

/// 再現できる乱数（テストの乱択を毎回同じにする）。手の中から引くので参照で共有する。
private final class Lehmer {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  func next(below bound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 33) % UInt64(max(1, bound)))
  }
}

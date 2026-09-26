import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面の契約——文書の写しを引いて描く・見えている範囲の通知・main の操作のスクロール・読むだけ。壊れると俯瞰と
/// 構文色の見えている範囲が本文とずれる、⌘F の次・前で一致が見えない、印や色が古い本文で描かれる、打鍵で本文が変わる。
@MainActor
final class MetalTextSurfaceTests: EngineTestCase {
  private func lines(_ count: Int, width: Int = 10) -> String {
    (0..<count).map { "line \($0) " + String(repeating: "x", count: width) }.joined(separator: "\n")
      + "\n"
  }

  /// 結ばれたとき・役割が届いたときに写しを引き、その版は文書の版。
  func testPullsTheDocumentsContent() throws {
    let opened = try open("let a = 1\nlet b = \"s\"\n")
    let content = try XCTUnwrap(opened.surface.material.read().content)
    XCTAssertEqual(content.version, opened.document.version)
    XCTAssertEqual(content.text.length, opened.document.text.length)
    XCTAssertFalse(content.roles.roles(in: NSRange(location: 0, length: 20)).isEmpty, "役割が届いている")
  }

  /// `scroll(toTop:)` と `viewport` は互いに逆——先頭の行・隠れている割合・可視行数を今の面と同じ意味で返す。
  func testViewportIsTheInverseOfScrollToTop() throws {
    let opened = try open(lines(300), size: CGSize(width: 800, height: 604))
    let text = opened.document.text
    opened.surface.scroll(toTop: text.lineStart(50), hiddenFraction: 0.25)
    let viewport = opened.surface.viewport
    XCTAssertEqual(viewport.firstVisible, text.lineStart(50))
    XCTAssertEqual(viewport.hiddenFraction, 0.25, accuracy: 1e-9)
    XCTAssertEqual(viewport.visibleLines, 600.0 / 18, accuracy: 1e-9, "上端の余白を除いた高さ")
    XCTAssertEqual(opened.document.viewportLines.first, 50.25, accuracy: 1e-9)
  }

  /// 最終行が最上段に来るまで送れ、それより先は止まる。
  func testScrollsUntilTheLastLineIsAtTheTop() throws {
    let opened = try open(lines(100), size: CGSize(width: 800, height: 604))
    opened.document.scroll(toFirstLine: 1_000)
    XCTAssertEqual(opened.document.viewportLines.first, 100, accuracy: 1e-9, "末尾の空行が最上段")
  }

  /// 見えるところまで最小限スクロールする——縦に見えていれば縦は動かず、横に隠れていれば横だけ寄る。
  func testScrollToVisibleMovesMinimally() throws {
    let opened = try open(lines(100, width: 300), size: CGSize(width: 800, height: 604))
    let text = opened.document.text
    let target = text.lineStart(10) + 280
    opened.surface.scrollToVisible(NSRange(location: target, length: 1))
    XCTAssertEqual(opened.surface.viewport.firstVisible, 0, "縦は見えているので動かない")
    XCTAssertGreaterThan(opened.surface.viewport.hiddenColumns, 0, "横に寄る")
    let columns = opened.surface.viewport
    XCTAssertLessThanOrEqual(281, columns.hiddenColumns + columns.visibleColumns + 0.5)
    opened.surface.scrollToVisible(NSRange(location: text.lineStart(80), length: 0))
    XCTAssertEqual(opened.surface.viewport.hiddenColumns, 0, "行頭へ戻る")
    XCTAssertGreaterThan(opened.document.viewportLines.first, 40, "下の行が見えるまで送る")
  }

  /// 行を見えている高さの中央へ置く（アニメーションしない）。
  func testScrollToCenterPlacesTheLineInTheMiddle() throws {
    let opened = try open(lines(300), size: CGSize(width: 800, height: 604))
    opened.surface.scrollToCenter(opened.document.text.lineStart(150))
    let (first, visible) = opened.document.viewportLines
    XCTAssertEqual(first + visible / 2, 150.5, accuracy: 0.01)
  }

  /// 指の出来事の量はその場で位置に入り、見えている範囲はその呼び出しの中で文書へ知らされる。
  func testWheelEventNotifiesTheViewportSynchronously() throws {
    let opened = try open(lines(300), size: CGSize(width: 800, height: 604))
    var notified = 0
    opened.document.onViewportChange = { notified += 1 }
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -90, wheel2: 0,
        wheel3: 0))
    opened.surface.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
    XCTAssertEqual(notified, 1)
    XCTAssertEqual(opened.document.viewportLines.first, 5, accuracy: 1e-9)
  }

  /// 読むだけ——打鍵・クリックで本文は変わらず、落ちない。
  func testKeysDoNotChangeTheText() throws {
    let opened = try open("let a = 1\n")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = opened.surface.view
    window.makeFirstResponder(opened.surface.responder)
    for key in ["a", "\r", "\u{7f}"] {
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
          context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
          keyCode: 0))
      opened.surface.responder.keyDown(with: event)
    }
    XCTAssertFalse(opened.surface.responder.tryToPerform(Selector(("copy:")), with: nil))
    XCTAssertEqual(opened.document.version, 0)
    XCTAssertFalse(opened.document.isDirty)
    window.contentView = nil
  }

  /// 本文の丸ごとの置き換え（外部変更の差し替え）は文書へ渡り、戻ったら新しい写しを描く。キャレットは収まる。
  func testReplaceAllReachesTheDocument() throws {
    let opened = try open("0123456789\n")
    opened.surface.selectedRange = NSRange(location: 9, length: 0)
    opened.surface.replaceAll(with: "abc\n")
    XCTAssertEqual(opened.document.text.substring(NSRange(location: 0, length: 4)), "abc\n")
    XCTAssertEqual(opened.surface.material.read().content?.version, opened.document.version)
    XCTAssertEqual(opened.surface.selectedRange, NSRange(location: 4, length: 0))
  }

  /// 行の印はオフセットで届き、引いた写しで行へ写す（区間の最後の字の行まで。削除は次の行の上端）。
  func testLineMarksAreMappedToRows() throws {
    let opened = try open("a\nb\nc\nd\n", waitForColors: false)
    opened.document.baseline = "a\nX\nc\nq\nd\n"
    XCTAssertTrue(opened.document.waitUntilCaughtUp())
    let marks = opened.surface.material.read().marks
    XCTAssertEqual(marks.bars, [RowMarks.Bar(rows: 1...1, kind: .modified)])
    XCTAssertEqual(marks.deletions, [RowMarks.Deletion(row: 3, atBottom: false)])
  }

  /// 面が閉じたら、描画スレッドが写しの最後の参照を手放す（大きな木の解放を main で行わない）。
  func testClosingReleasesTheContentOnTheRenderThread() throws {
    var opened: Opened? = try open("let a = 1\n")
    let material = try XCTUnwrap(opened?.surface.material)
    XCTAssertNotNil(material.read().content)
    opened = nil
    _ = RenderThread.shared.performAndWait { _ in true }
    XCTAssertNil(material.read().content)
  }
}

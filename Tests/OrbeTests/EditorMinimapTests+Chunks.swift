import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// ミニマップの字のチャンクの画像——何を捨てて描き直し、何を覚えておくか。
///
/// 壊れると何が起きるか。打鍵のたびに窓ぶんの字を描き直して大きな文書で打鍵が重くなる、文書を通すと画像が溜まり続ける。
/// 逆に捨て損なうと、コメントを閉じた・外観を切り替えた・文書を切り替えた後も、ミニマップに古い色や前の文書の字が残る。
extension EditorMinimapTests {
  /// 字のチャンク: 打鍵は編集の行のチャンクだけ捨て、行が増えれば編集より後ろのチャンクも捨てる。
  func testTypingDropsOnlyTheEditedChunkAndNewlinesDropTheChunksAfterIt() throws {
    let hosted = try hostOverview(numberedLines(300), height: 800)
    let view = hosted.pane.minimap
    view.display()
    let warm = view.cachedChunks
    XCTAssertTrue(warm.isSuperset(of: [0, 1, 2]), "窓のチャンクを覚えている: \(warm)")

    hosted.document.surface.selectedRange = NSRange(
      location: hosted.document.lineIndex.start(ofRow: 100), length: 0)
    hosted.window.makeFirstResponder(hosted.document.surface.responder)
    hosted.document.surface.responder.keyDown(with: .key("x", []))
    XCTAssertEqual(warm.subtracting(view.cachedChunks), [1], "行 100 のチャンクだけ捨てる")

    view.display()
    hosted.document.surface.responder.keyDown(with: .key("\n", []))
    XCTAssertEqual(view.cachedChunks.filter { $0 >= 1 }, [], "行が増えれば以降を捨てる")
    XCTAssertTrue(view.cachedChunks.contains(0), "手前は残る")
  }

  /// 字のチャンクの画像は上限までしか覚えず、超えたら最も長く使っていないものから捨てる——1MB・50 万行の文書を上限の
  /// 3 倍のチャンクぶん通し、末尾まで飛んでも上限を超えない。最近の窓は残り、最初のチャンクは捨てられている。
  func testChunkImagesStayWithinTheCapacityAndKeepTheRecentOnes() throws {
    let hosted = try hostOverview(String(repeating: "x\n", count: 500_000))
    let view = hosted.pane.minimap
    let document = hosted.document
    let capacity = MinimapChunks.capacity
    func show(_ line: Int) throws -> ClosedRange<Int> {
      document.scroll(toFirstLine: CGFloat(line))
      view.display()
      XCTAssertLessThanOrEqual(view.cachedChunks.count, capacity, "行 \(line)")
      let lines = try XCTUnwrap(view.placement).lines
      let chunk = MinimapChunks.lines
      return (lines.lowerBound / chunk)...((lines.upperBound - 1) / chunk)
    }
    var seen = Set<Int>()
    var recent: ClosedRange<Int>?
    var line = 0
    while line < 3 * capacity * MinimapChunks.lines {
      recent = try show(line)
      seen.formUnion(view.cachedChunks)
      line += 150
    }
    XCTAssertGreaterThan(seen.count, 2 * capacity, "上限を超える数のチャンクを通った")
    XCTAssertFalse(view.cachedChunks.contains(0), "最初のチャンクは捨てた")
    let last = try show(document.lineIndex.lineCount - 1)
    XCTAssertTrue(Set(last).isSubset(of: view.cachedChunks), "末尾の窓は覚えている")
    XCTAssertTrue(
      Set(try XCTUnwrap(recent)).isSubset(of: view.cachedChunks), "直前に見ていた窓は残る")
  }

  /// 役割が変わった区間の字は描き直す——ブロックコメントの開きを消すと、編集した行から離れた（別のチャンクの）行も
  /// コメントの色から外れる。
  func testRoleChangesRedrawGlyphsBeyondTheEditedChunk() throws {
    let text = "/*\n" + String(repeating: "abc\n", count: 130) + "*/\n"
    let hosted = try hostOverview(text, name: "r-\(UUID().uuidString).swift", colored: true)
    let document = hosted.document
    let far = document.lineIndex.start(ofRow: 100)
    pumpMain(
      until: { document.roleSpans(in: NSRange(location: far, length: 3)).first?.role == .comment },
      "前提: 行 100 はコメントの中")
    let view = hosted.pane.minimap
    view.display()
    let comment = try ViewPixels(view).strongest(in: cell(view, row: 100, column: 1))

    document.surface.selectedRange = NSRange(location: 0, length: 2)
    hosted.window.makeFirstResponder(document.surface.responder)
    document.surface.responder.keyDown(with: .key("x", []))
    pumpMain(
      until: { document.roleSpans(in: NSRange(location: far, length: 3)).first?.role != .comment },
      "コメントが解ける")
    view.display()
    let uncommented = try ViewPixels(view).strongest(in: cell(view, row: 100, column: 1))
    XCTAssertGreaterThan(uncommented.alphaComponent, 0.2, "字はある")
    XCTAssertGreaterThan(
      abs(uncommented.redComponent - comment.redComponent)
        + abs(uncommented.greenComponent - comment.greenComponent)
        + abs(uncommented.blueComponent - comment.blueComponent), 0.2,
      "コメントの色から変わる: \(comment) → \(uncommented)")
  }

  /// 外観を切り替えると、覚えていた字の画像を捨てて新しい外観の色で描き直す。
  func testSwitchingTheAppearanceRedrawsTheGlyphsInItsColors() throws {
    let hosted = try hostOverview("MMMM\n")
    let view = hosted.pane.minimap
    view.display()
    let dark = try ViewPixels(view).strongest(in: cell(view, row: 0, column: 1))
    hosted.window.appearance = NSAppearance(named: .aqua)
    view.display()
    let light = try ViewPixels(view).strongest(in: cell(view, row: 0, column: 1))
    XCTAssertGreaterThan(light.alphaComponent, 0.2, "字はある")
    XCTAssertGreaterThan(
      dark.redComponent, light.redComponent + 0.3,
      "素の文字色が dark の明るい色から light の暗い色へ: \(dark) → \(light)")
  }

  /// 文書を切り替えると、ミニマップは新しい文書の字を描く（前の文書の字の画像を使い回さない）。
  func testSwitchingDocumentsDrawsTheNewDocument() throws {
    let hosted = try hostOverview("xxxxxxxx\n")
    let view = hosted.pane.minimap
    view.display()
    XCTAssertGreaterThan(try ViewPixels(view).alpha(in: cell(view, row: 0, column: 6)).max, 0.2)

    _ = try hosted.tab.editor.open(try caseFile("other.txt", "x\n"))
    hosted.pane.layoutSubtreeIfNeeded()
    let pixels = try ViewPixels(view)
    XCTAssertGreaterThan(pixels.alpha(in: cell(view, row: 0, column: 0)).max, 0.2, "新しい文書の字")
    XCTAssertEqual(pixels.alpha(in: cell(view, row: 0, column: 6)).max, 0, "前の文書の字は残らない")
  }
}

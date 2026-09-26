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
      location: hosted.document.text.lineStart(100), length: 0)
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
    let last = try show(document.text.lineCount - 1)
    XCTAssertTrue(Set(last).isSubset(of: view.cachedChunks), "末尾の窓は覚えている")
    XCTAssertTrue(
      Set(try XCTUnwrap(recent)).isSubset(of: view.cachedChunks), "直前に見ていた窓は残る")
  }

  /// 裏から届いた役割が変わった区間の字は描き直す——ブロックコメントの開きを消すと、編集した行から離れた（別のチャンク
  /// の）行も、役割が届いたときにチャンクを捨ててコメントの色から外れる。
  func testRoleChangesRedrawGlyphsBeyondTheEditedChunk() throws {
    let text = "/*\n" + String(repeating: "abc\n", count: 130) + "*/\n"
    let hosted = try hostOverview(text, name: "r-\(UUID().uuidString).swift", colored: true)
    let document = hosted.document
    let far = document.text.lineStart(100)
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertEqual(
      document.roles.roles(in: NSRange(location: far, length: 3)).first?.role, .comment,
      "前提: 行 100 はコメントの中")
    let view = hosted.pane.minimap
    view.display()
    let comment = try ViewPixels(view).strongest(in: cell(view, row: 100, column: 1))

    document.surface.selectedRange = NSRange(location: 0, length: 2)
    hosted.window.makeFirstResponder(document.surface.responder)
    document.surface.responder.keyDown(with: .key("x", []))
    XCTAssertTrue(view.cachedChunks.contains(1), "打鍵は編集の行のチャンクだけを捨てる")
    view.display()
    XCTAssertTrue(document.waitUntilCaughtUp())
    XCTAssertTrue(try XCTUnwrap(view.layer).needsDisplay(), "役割が届いたら描き直しを頼む")
    XCTAssertNotEqual(
      document.roles.roles(in: NSRange(location: far, length: 3)).first?.role, .comment,
      "コメントが解ける")
    XCTAssertFalse(view.cachedChunks.contains(1), "役割が届いた区間のチャンクを捨てる")
    view.display()
    let uncommented = try ViewPixels(view).strongest(in: cell(view, row: 100, column: 1))
    XCTAssertGreaterThan(uncommented.alphaComponent, 0.2, "字はある")
    XCTAssertGreaterThan(
      abs(uncommented.redComponent - comment.redComponent)
        + abs(uncommented.greenComponent - comment.greenComponent)
        + abs(uncommented.blueComponent - comment.blueComponent), 0.2,
      "コメントの色から変わる: \(comment) → \(uncommented)")
  }

  /// 外部変更の差し替え（全体の置換）で 1 行だけ変わったとき、ミニマップは変わった行のチャンクだけを組み直し、他のチャンクの
  /// 字は色付きのまま残る。
  func testReplacingTheWholeTextKeepsTheUnchangedChunks() throws {
    let text = String(repeating: "struct S {}\n", count: 300)
    let hosted = try hostOverview(
      text, height: 800, name: "x-\(UUID().uuidString).swift", colored: true)
    let document = hosted.document
    XCTAssertTrue(document.waitUntilCaughtUp())
    let view = hosted.pane.minimap
    view.display()
    XCTAssertTrue(view.cachedChunks.isSuperset(of: [0, 1, 2]), "前提: 窓のチャンクを覚えている")
    let line100 = document.text.lineStart(100)
    document.surface.replaceAll(
      with: (text as NSString).replacingCharacters(
        in: NSRange(location: line100, length: 6), with: "class "))
    XCTAssertEqual(view.cachedChunks.intersection([0, 1, 2]), [0, 2], "変わった行 100 のチャンクだけ捨てる")
    view.display()
    let layout = try XCTUnwrap(view.placement)
    let keyword = try ViewPixels(view).strongest(
      in: NSRect(x: gutter(view) + 1, y: layout.y(ofLine: 10), width: 1, height: 2))
    XCTAssertTrue(Hue.blue(keyword), "変わっていない行の struct は keyword の青のまま: \(keyword)")
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

  /// 役割が揃っていれば、スクロールで新しく見えたチャンクもその描画から役割の色で描く。
  func testScrolledInChunksDrawTheRolesOnTheirFirstDraw() throws {
    let text = String(repeating: "struct S {}\n", count: 3000)
    let hosted = try hostOverview(
      text, height: 800, name: "p-\(UUID().uuidString).swift", colored: true)
    XCTAssertTrue(hosted.document.waitUntilCaughtUp())
    let view = hosted.pane.minimap
    view.display()
    hosted.document.scroll(toFirstLine: 2000)
    hosted.pane.layoutSubtreeIfNeeded()
    view.display()
    let layout = try XCTUnwrap(view.placement)
    let colored = try ViewPixels(view).strongest(
      in: NSRect(
        x: gutter(view) + 1, y: layout.y(ofLine: layout.lines.lowerBound + 10), width: 1, height: 2
      ))
    XCTAssertTrue(Hue.blue(colored), "新しく見えた struct も keyword の青: \(colored)")
  }

  /// 打鍵で捨てたチャンクは色付きのまま描き直す（打っている間に単色へ戻らない）。
  func testChunksRedrawnAfterTypingStayColored() throws {
    let hosted = try hostOverview(
      String(repeating: "struct S {}\n", count: 300), height: 800,
      name: "t-\(UUID().uuidString).swift", colored: true)
    let document = hosted.document
    XCTAssertTrue(document.waitUntilCaughtUp())
    let view = hosted.pane.minimap
    view.display()
    document.surface.selectedRange = NSRange(location: document.text.lineStart(100), length: 0)
    hosted.window.makeFirstResponder(document.surface.responder)
    document.surface.responder.keyDown(with: .key("x", []))
    XCTAssertFalse(view.cachedChunks.contains(1), "前提: 行 100 のチャンクを捨てた")
    view.display()
    let layout = try XCTUnwrap(view.placement)
    let keyword = try ViewPixels(view).strongest(
      in: NSRect(x: gutter(view) + 1, y: layout.y(ofLine: 101), width: 1, height: 2))
    XCTAssertTrue(Hue.blue(keyword), "描き直したチャンクは色付き: \(keyword)")
  }
}

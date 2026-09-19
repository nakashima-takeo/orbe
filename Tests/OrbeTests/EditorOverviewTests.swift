import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 本体の右の俯瞰——縁｜ミニマップ｜印の列が本物のテキスト面の右に立ち、帯がスクロールに連続で追従し、長い文書で
/// 窓が比例でスライドし、クリックでその行が本文の中央に来て、キャレットの印が選択に付いてくる。縦スクローラーは
/// 出ない。縮図の覚え方は編集で絞って捨てる。
///
/// 壊れると何が起きるか。帯がスクロールと合わず「どこを見ているか」が嘘になる。長い文書で末尾の行がミニマップに
/// 現れない。クリックが別の行へ飛ぶ。打鍵のたびに窓ぶんの構文 query が走って大きな文書で打鍵が重くなる。
@MainActor
final class EditorOverviewTests: OrbeTestCase {
  private let style = EditorStyle.make()
  private let overview = EditorStyle.overview()

  @MainActor private struct Hosted {
    let tab: TerminalTab
    let pane: EditorPaneView
    let document: EditorDocument
    let window: NSWindow
    var scroll: NSScrollView { document.surface.view.subviews.first as! NSScrollView }
  }

  private func host(_ text: String, height: CGFloat = 400) throws -> Hosted {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 700, height: height)
    window.appearance = NSAppearance(named: .darkAqua)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let document = try tab.editor.open(try caseFile("o-\(UUID().uuidString).txt", text))
    pane.layoutSubtreeIfNeeded()
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "viewport が出る")
    return Hosted(tab: tab, pane: pane, document: document, window: window)
  }

  /// 俯瞰の描画 1 枚の alpha（0…255）。透明な地に描くので、塗られた画素だけ alpha を持つ。y は上から。
  private func alpha(_ view: EditorOverviewView, _ x: CGFloat, _ y: CGFloat) throws -> Int {
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return Int(
      try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))).alphaComponent * 255)
  }

  /// n 行（末尾の改行で索引は n + 1 行になる）。
  private func lines(_ n: Int) -> String { (1...n).map { "line \($0)\n" }.joined() }

  /// 文書比例の写しの 1 行ぶんの高さ（印の列）。
  private func rowScale(_ hosted: Hosted) -> CGFloat {
    hosted.pane.overview.bounds.height / CGFloat(hosted.document.lineIndex.lineCount)
  }

  func testOverviewColumnStandsRightOfTheSurfaceAndTheSurfaceHasNoVerticalScroller() throws {
    let hosted = try host(lines(10))
    let pane = hosted.pane
    XCTAssertEqual(pane.overview.frame.width, 1 + 100 + 13)
    XCTAssertEqual(pane.overview.frame.maxX, pane.bodyRect.maxX)
    XCTAssertEqual(pane.surfaceRect.width, pane.bodyRect.width - 114)
    XCTAssertEqual(hosted.document.surface.view.frame, pane.surfaceRect)
    XCTAssertFalse(pane.overview.isHidden)
    XCTAssertFalse(hosted.scroll.hasVerticalScroller, "位置は俯瞰が担う")
    XCTAssertTrue(hosted.scroll.hasHorizontalScroller, "横はそのまま")
    XCTAssertTrue(try alpha(pane.overview, 0.5, 100) > 0, "左の縁")

    hosted.tab.editor.close(hosted.document)
    pane.layoutSubtreeIfNeeded()
    XCTAssertTrue(pane.overview.isHidden, "文書が無ければ隠れる")
    XCTAssertEqual(pane.surfaceRect, pane.bodyRect)
  }

  /// 収まる文書: 帯は上端から可視行数ぶん、行の矩形は 6 下から 4 刻み。半行スクロールすると帯は 2px 下がる（行単位で
  /// 跳ばない）。
  func testBandFollowsScrollContinuouslyOnAShortDocument() throws {
    let hosted = try host(lines(60))
    let view = hosted.pane.overview
    let visible = hosted.document.surface.viewport.visibleLines
    let bandBottom = overview.topInset + visible * overview.pitch
    let x = view.bounds.minX + 1 + 50
    XCTAssertTrue(try alpha(view, x, 1) > 0, "帯は上端 0 から")
    XCTAssertTrue(try alpha(view, x, bandBottom - 1) > 0)
    XCTAssertEqual(try alpha(view, x, bandBottom + 3), 0, "帯の下は地（行の矩形は x=8〜なので 50 には無い）")

    hosted.scroll.contentView.scroll(to: NSPoint(x: 0, y: style.lineHeight / 2))
    hosted.scroll.reflectScrolledClipView(hosted.scroll.contentView)
    pumpMain(until: { hosted.document.surface.viewport.hiddenFraction > 0.4 }, "半行隠れる")
    XCTAssertEqual(try alpha(view, x, 1), 0, "帯が 2px 下がる")
    XCTAssertTrue(try alpha(view, x, 3) > 0)
    XCTAssertTrue(try alpha(view, x, bandBottom + 1) > 0)
  }

  /// 長い文書: 先頭で帯は上端、末尾で帯は下端（窓が比例でスライドし、最後の行の矩形が見える）。
  func testMinimapWindowSlidesSoTheLastLineIsReachable() throws {
    let hosted = try host(lines(1000))
    let view = hosted.pane.overview
    let x = view.bounds.minX + 1 + 50
    XCTAssertTrue(try alpha(view, x, 1) > 0, "先頭で帯は上端")
    XCTAssertEqual(try alpha(view, x, view.bounds.height - 2), 0)

    hosted.document.surface.responder.perform(
      #selector(NSResponder.moveToEndOfDocument(_:)), with: nil)
    hosted.document.surface.scrollToCenter(hosted.document.lineIndex.start(ofRow: 999))
    pumpMain(
      until: {
        hosted.document.lineIndex.point(at: hosted.document.surface.viewport.firstVisible).row > 900
      },
      "末尾へ")
    XCTAssertTrue(try alpha(view, x, view.bounds.height - 2) > 0, "末尾で帯は下端")
    XCTAssertEqual(try alpha(view, x, 1), 0)
    let lastRow = view.bounds.height - 4 + 1  // 最後の行の矩形（下端 − ピッチ ＋ 行高の中）
    XCTAssertTrue(try alpha(view, view.bounds.minX + 1 + 8 + 2, lastRow) > 0, "最後の行の縮図が窓に入る")
  }

  /// ミニマップのクリックでその行が本文の中央に来る。縁と印の列のクリックは何もしない。
  func testClickingTheMinimapCentersThatLine() throws {
    let hosted = try host(lines(1000))
    let view = hosted.pane.overview
    let visible = hosted.document.surface.viewport.visibleLines
    let point = view.convert(
      NSPoint(x: 50, y: overview.topInset + 80 * overview.pitch + 1), to: nil)
    view.mouseDown(
      with: try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: hosted.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1)))
    pumpMain(until: { hosted.document.surface.viewport.firstVisible > 0 }, "スクロールする")
    let first = hosted.document.lineIndex.point(at: hosted.document.surface.viewport.firstVisible)
      .row
    XCTAssertEqual(CGFloat(first), 80 - visible / 2, accuracy: 1.5, "行 80 が中央")

    let before = hosted.document.surface.viewport
    view.jump(to: NSPoint(x: 0.5, y: 300))
    view.jump(to: NSPoint(x: 1 + 100 + 6, y: 300))
    XCTAssertEqual(hosted.document.surface.viewport, before, "縁と印の列では動かない")
  }

  /// 印の列のカーソルの印は選択の行に比例して置かれ、動かせば付いてくる。
  func testCaretMarkFollowsTheSelection() throws {
    let hosted = try host(lines(100))
    let view = hosted.pane.overview
    let x = view.bounds.minX + 1 + 100 + overview.caretMarkX + 2
    let scale = rowScale(hosted)
    XCTAssertTrue(try alpha(view, x, 0.5) > 0, "先頭行の印")
    hosted.document.surface.selectedRange = NSRange(
      location: hosted.document.lineIndex.start(ofRow: 50), length: 0)
    pumpMain(until: { (try? self.alpha(view, x, 50 * scale + 0.5)) ?? 0 > 0 }, "行 50 の印")
    XCTAssertEqual(try alpha(view, x, 0.5), 0, "先頭行の印は消える")
  }

  /// 追加・変更の行はミニマップの左端 2px と印の列に、それぞれの色で出る。削除の境は出ない。
  func testGitMarksAppearInTheMinimapEdgeAndTheMarksColumn() throws {
    let hosted = try host(lines(20))
    let view = hosted.pane.overview
    hosted.document.baseline = lines(20).replacingOccurrences(of: "line 5\n", with: "line five\n")
      .replacingOccurrences(of: "line 10\n", with: "")
    pumpMain(until: { hosted.document.hunks.count == 2 }, "ハンク")
    // 左端の印は帯（α .07 ≈ 18）の上に乗るので、帯より濃いかで見る。
    let edgeX = view.bounds.minX + 1 + overview.minimapMarkX + 1
    XCTAssertTrue(
      try alpha(view, edgeX, overview.topInset + 4 * overview.pitch + 1) > 100, "行 5 の左端の印")
    XCTAssertTrue(
      try alpha(view, edgeX, overview.topInset + 6 * overview.pitch + 1) < 40, "行 7 には無い")
    let barX = view.bounds.minX + 1 + 100 + overview.marksBarX + 2
    let scale = rowScale(hosted)
    XCTAssertTrue(try alpha(view, barX, 4 * scale + 1) > 0, "印の列の行 5")
    XCTAssertTrue(try alpha(view, barX, 9 * scale + 1) > 0, "行 10（baseline に無い＝追加）")
    XCTAssertEqual(try alpha(view, barX, 15 * scale + 1), 0)
  }

  /// 縮図のキャッシュ: 打鍵は編集の行のチャンクだけ捨て、行が増えれば編集より後ろのチャンクも捨てる。
  func testTypingDropsOnlyTheEditedChunkAndNewlinesDropTheChunksAfterIt() throws {
    let hosted = try host(lines(300), height: 800)
    let view = hosted.pane.overview
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
}

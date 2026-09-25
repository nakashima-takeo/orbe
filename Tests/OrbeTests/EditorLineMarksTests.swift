import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 本物のテキストエンジンに載る行の装備——git の印（3 色・三角）がスクロールと編集に追従する、インデント線・
/// 丸点・URL 下線が本文の座標に立つ、⌘クリックだけが URL を開いて素のクリックはキャレットを置く。
/// 装備は overlay で、テストと静止画が緑でも同期が壊れれば実機で消える（u4 の教訓）ので、位置は画素で見る。
///
/// 壊れると何が起きるか。印がスクロールで置き去りになり別の行に見える。打鍵しても印が動かず、どの行を変えたか
/// 分からない。⌘クリックが上流の選択と衝突して URL が開かないか、素のクリックで勝手にブラウザが開く。
@MainActor
final class EditorLineMarksTests: OrbeTestCase {
  let style = EditorStyle.make()
  var cell: CGFloat { (" " as NSString).size(withAttributes: [.font: style.font]).width }
  /// 本文の左端（行番号 50 ＋ 印の列 19）。
  var bodyX: CGFloat { style.gutterWidth + style.marks.gutterWidth }
  /// 印のバーの中（列の左 ＋ 左余白 2 ＋ 幅 3 の中央）。
  var barX: CGFloat { style.gutterWidth + style.marks.barInset + 1.5 }
  func rowMidY(_ line: Int) -> CGFloat {
    style.topInset + CGFloat(line - 1) * style.lineHeight + style.lineHeight / 2
  }

  /// 黒地の窓に載せた文書の面（装備の色は地との合成で読む）。
  struct Hosted {
    let session: EditorSession
    let document: EditorDocument
    let ground: Ground
    let window: NSWindow
  }

  func host(_ text: String, size: NSSize = NSSize(width: 400, height: 200)) throws
    -> Hosted
  {
    let url = try caseFile("marks-\(UUID().uuidString).swift", text)
    let session = EditorSession(
      surfaces: EditorSurfaces(
        queriesRoot: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()))
    let document = try session.open(url)
    let ground = Ground(frame: NSRect(origin: .zero, size: size))
    document.surface.view.frame = ground.bounds
    ground.addSubview(document.surface.view)
    let window = NSWindow(
      contentRect: ground.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = ground
    ground.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    // 本文の最初の行が描かれるまで待つ（固定で眠らない。overlay の frame は layout と viewport の通知で置かれる）。
    waitDrawn {
      try stride(from: self.bodyX, to: self.bodyX + 24 * self.cell, by: 1).contains {
        !self.isBlack(try self.rgb(ground, $0, self.rowMidY(1)))
      }
    }
    return Hosted(session: session, document: document, ground: ground, window: window)
  }

  final class Ground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.black.setFill()
      bounds.fill()
    }
  }

  /// 描いて色を引く（flipped 座標。y は上から）。
  func rgb(_ view: NSView, _ x: CGFloat, _ y: CGFloat) throws -> [Int] {
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let color = try XCTUnwrap(
      rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
    return [color.redComponent, color.greenComponent, color.blueComponent].map { Int($0 * 255) }
  }

  func isBlack(_ rgb: [Int]) -> Bool { rgb.allSatisfy { $0 <= 3 } }

  /// 1px の線は device pixel に揃えて描かれるので、x の前後 1 device pixel も見る。
  func hasInk(_ view: NSView, _ x: CGFloat, _ y: CGFloat) throws -> Bool {
    try [x - 0.5, x, x + 0.5].contains { !isBlack(try rgb(view, $0, y)) }
  }
  func isGreen(_ c: [Int]) -> Bool { !isBlack(c) && c[1] > c[0] && c[1] > c[2] }
  func isBlue(_ c: [Int]) -> Bool { !isBlack(c) && c[2] > c[0] && c[2] > c[1] }
  func isRed(_ c: [Int]) -> Bool { !isBlack(c) && c[0] > c[1] && c[0] > c[2] }

  /// 描き直しは layout の後に載るので、成立まで描いて測り直す。
  func waitDrawn(
    _ condition: @escaping () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    pumpMain(until: { (try? condition()) ?? false }, timeout: 5, "描かれる", file: file, line: line)
  }

  /// 黒地に `color` を塗った画素（面の合成の答えを同じ描画経路で取る）。
  func onBlack(_ color: NSColor) throws -> [Int] {
    let swatch = Swatch(frame: NSRect(x: 0, y: 0, width: 20, height: 20), color: color)
    let reference = NSWindow(
      contentRect: swatch.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    reference.appearance = NSAppearance(named: .darkAqua)
    reference.contentView = swatch
    return try rgb(swatch, 10, 10)
  }

  func matches(_ lhs: [Int], _ rhs: [Int]) -> Bool {
    zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 2 }
  }

  /// 黒地に style の色を塗った見本（合成の答えを同じ描画経路で取る）。
  final class Swatch: NSView {
    let color: NSColor
    init(frame: NSRect, color: NSColor) {
      self.color = color
      super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.black.setFill()
      bounds.fill()
      color.setFill()
      bounds.fill()
    }
  }

  // MARK: - git の印

  /// 追加＝緑・変更＝青のバーがその行に、削除の三角がその境に出て、印の無い行の列は地のまま。バーの色は
  /// 見本の α .85 で地に合成される。
  func testMarksShowTheThreeKindsAtTheirLines() throws {
    let hosted = try host("a\nB\nc\nd\ne\n")
    let document = hosted.document
    let ground = hosted.ground
    document.baseline = "a\nb\nc\nx\ne\n"
    XCTAssertEqual(document.hunks.count, 2, "2 行目と 4 行目が変更")
    waitDrawn { self.isBlue(try self.rgb(ground, self.barX, self.rowMidY(2))) }
    XCTAssertTrue(isBlue(try rgb(ground, barX, rowMidY(4))))
    XCTAssertTrue(isBlack(try rgb(ground, barX, rowMidY(1))), "印の無い行")
    XCTAssertTrue(isBlack(try rgb(ground, barX, rowMidY(3))))
    XCTAssertTrue(isBlack(try rgb(ground, style.gutterWidth + 0.5, rowMidY(2))), "バーの左（余白 2）は地")
    XCTAssertTrue(isBlack(try rgb(ground, style.gutterWidth + 6.5, rowMidY(2))), "バーの右も地")

    document.baseline = "a\nB\nc\nd\n"
    waitDrawn { self.isGreen(try self.rgb(ground, self.barX, self.rowMidY(5))) }
    XCTAssertTrue(isBlack(try rgb(ground, barX, rowMidY(2))), "baseline が変われば前の印は消える")

    document.baseline = "a\nz\nB\nc\nd\ne\n"
    waitDrawn { self.isRed(try self.rgb(ground, self.barX, self.rowMidY(2) - 9)) }
    XCTAssertTrue(
      isRed(try rgb(ground, style.gutterWidth + 4, rowMidY(2) - 9)), "三角は境（2 行目の上端）に中央合わせ")
    XCTAssertTrue(isBlack(try rgb(ground, barX, rowMidY(2) + 5)), "三角の下は地（バーではない）")

    document.baseline = "a\nB\nc\nd\n"
    waitDrawn { self.isGreen(try self.rgb(ground, self.barX, self.rowMidY(5))) }
    let bar = try rgb(ground, barX, rowMidY(5))
    let expected = try onBlack(style.marks.added)
    XCTAssertTrue(matches(bar, expected), "面の色は style の色（α 込み）そのまま: \(bar) ≈ \(expected)")
  }

  /// 先頭行の上の削除は、三角を上端から下向きに置く（境の y = 0 に中央合わせすると上半分が切れる）。
  func testADeletionAboveTheFirstLineIsDrawnFromTheTopEdge() throws {
    let hosted = try host("a\nb\n")
    let ground = hosted.ground
    hosted.document.baseline = "z\na\nb\n"
    let tip = style.gutterWidth + style.marks.barInset + 2
    waitDrawn { self.isRed(try self.rgb(ground, tip, self.style.topInset + 3)) }
    XCTAssertTrue(isBlack(try rgb(ground, tip, style.topInset + 9)), "三角は一辺 6 で終わり、その下は地")
    XCTAssertTrue(isBlack(try rgb(ground, barX, rowMidY(1))), "1 行目にバーは無い")
  }

  /// 行番号は幅 50 の中に右寄せで収まり（右余白 8）、その右の印の列（19）は数字に侵されない——桁が増えても
  /// 数字と印が重ならず、本文はその右端（69）から始まる。
  func testLineNumbersStayRightAlignedBesideTheMarkColumn() throws {
    let text = (1...12).map { "line \($0)\n" }.joined()
    let hosted = try host(text, size: NSSize(width: 400, height: 300))
    let ground = hosted.ground
    hosted.document.baseline = text.replacingOccurrences(of: "line 12\n", with: "twelve\n")
    let y = rowMidY(12)
    let digitsRight = style.gutterWidth - style.gutterTrailingInset
    waitDrawn { self.isBlue(try self.rgb(ground, self.barX, y)) }
    waitDrawn {
      try stride(from: digitsRight - 12, to: digitsRight, by: 0.5).contains {
        !self.isBlack(try self.rgb(ground, $0, y))
      }
    }
    let clear = stride(from: digitsRight + 1, to: bodyX, by: 0.5).filter {
      !(style.gutterWidth + 1...style.gutterWidth + 6).contains($0)
    }
    for x in clear {
      XCTAssertTrue(isBlack(try rgb(ground, x, y)), "右余白と印の列（バー以外）に数字の字は無い: x=\(x)")
    }
    XCTAssertTrue(
      try stride(from: bodyX, to: bodyX + cell, by: 0.5).contains {
        !self.isBlack(try self.rgb(ground, $0, y))
      }, "本文の最初の字は印の列の右端の直後のセルにある")
  }

  /// 印は打鍵に追従する（同じ runloop の中で作り直され、次の描画に載る）。
  func testMarksFollowTyping() throws {
    let hosted = try host("a\nb\nc\n")
    let document = hosted.document
    let ground = hosted.ground
    let window = hosted.window
    document.baseline = "a\nb\nc\n"
    window.makeFirstResponder(document.surface.responder)
    document.surface.responder.perform(#selector(NSResponder.moveToEndOfDocument(_:)), with: nil)
    document.surface.responder.perform(#selector(NSResponder.moveUp(_:)), with: nil)
    document.surface.responder.keyDown(with: .key("x", []))
    XCTAssertEqual(document.surface.text, "a\nb\nxc\n")
    waitDrawn { self.isBlue(try self.rgb(ground, self.barX, self.rowMidY(3))) }
    XCTAssertTrue(isBlack(try rgb(ground, barX, rowMidY(2))))
  }

  /// スクロールしても印は行に付いてくる（viewport の overlay が clip view の bounds に置き直される）。
  func testMarksFollowScrolling() throws {
    let lines = (1...100).map { "line \($0)\n" }.joined()
    let hosted = try host(lines)
    let document = hosted.document
    let ground = hosted.ground
    document.baseline = lines.replacingOccurrences(of: "line 50\n", with: "line fifty\n")
    let scroll = try XCTUnwrap(document.surface.view.subviews.first as? NSScrollView)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 49 * style.lineHeight))
    scroll.reflectScrolledClipView(scroll.contentView)
    waitDrawn { self.isBlue(try self.rgb(ground, self.barX, self.rowMidY(1))) }
    XCTAssertTrue(isBlack(try rgb(ground, barX, rowMidY(2))))

    scroll.contentView.scroll(to: NSPoint(x: 0, y: 48 * style.lineHeight))
    scroll.reflectScrolledClipView(scroll.contentView)
    waitDrawn { self.isBlue(try self.rgb(ground, self.barX, self.rowMidY(2))) }
    XCTAssertTrue(isBlack(try rgb(ground, barX, rowMidY(1))))
  }

  /// 横にスクロールしても本文の装備は行に付いてくる（overlay の座標が container 基準のまま置き直される）。
  /// 長い行で横スクロールが起き、印は行番号の列にあるので無事な一方、線・点・下線だけが置き去りになる壊れ方を守る。
  func testDecorationsFollowHorizontalScrolling() throws {
    let long = String(repeating: "x", count: 100) + "  " + String(repeating: "x", count: 100)
    let hosted = try host("a\n  b  c \(long)\n    d\n")
    let ground = hosted.ground
    let document = hosted.document
    let scroll = try XCTUnwrap(document.surface.view.subviews.first as? NSScrollView)
    let guide = bodyX + 2 * cell
    let dot = bodyX + 3.5 * cell
    waitDrawn { try self.hasInk(ground, guide, self.rowMidY(3)) }
    XCTAssertFalse(isBlack(try rgb(ground, dot, rowMidY(2))), "前提: 丸点が見えている")

    let shift = 3 * cell
    scroll.contentView.scroll(to: NSPoint(x: shift, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    waitDrawn { !self.isBlack(try self.rgb(ground, dot - shift, self.rowMidY(2))) }
    XCTAssertFalse(try hasInk(ground, guide, rowMidY(3)), "線は 3 桁ぶん左（本文の左端の外）へ動いて見えない")
    XCTAssertTrue(isBlack(try rgb(ground, dot, rowMidY(2))), "元の位置には点が無い")

    // 100 桁右へ: 1 画面ぶん先の連続スペース（107 桁目）の点が、可視矩形の中に描かれる。
    scroll.contentView.scroll(to: NSPoint(x: 100 * cell, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    waitDrawn { !self.isBlack(try self.rgb(ground, self.bodyX + 7.5 * self.cell, self.rowMidY(2))) }
    XCTAssertTrue(isBlack(try rgb(ground, dot, rowMidY(3))), "短い行の右は地（線も点も無い）")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    waitDrawn { !self.isBlack(try self.rgb(ground, dot, self.rowMidY(2))) }
    XCTAssertTrue(try hasInk(ground, guide, rowMidY(3)), "戻れば線も戻る")
  }

}

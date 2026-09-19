import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 本物のテキストエンジンに載る行の装備——ガターの印（3 色・三角）がスクロールと編集に追従する、インデント線・
/// 丸点・URL 下線が本文の座標に立つ、⌘クリックだけが URL を開いて素のクリックはキャレットを置く。
/// 装備は overlay で、テストと静止画が緑でも同期が壊れれば実機で消える（u4 の教訓）ので、位置は画素で見る。
///
/// 壊れると何が起きるか。印がスクロールで置き去りになり別の行に見える。打鍵しても印が動かず、どの行を変えたか
/// 分からない。⌘クリックが上流の選択と衝突して URL が開かないか、素のクリックで勝手にブラウザが開く。
@MainActor
final class EditorLineMarksTests: OrbeTestCase {
  private let style = EditorStyle.make()
  private var cell: CGFloat { (" " as NSString).size(withAttributes: [.font: style.font]).width }
  /// 本文の左端（行番号 50 ＋ 印の列 19）。
  private var bodyX: CGFloat { style.gutterWidth + style.marks.gutterWidth }
  /// 印のバーの中（列の左 ＋ 左余白 2 ＋ 幅 3 の中央）。
  private var barX: CGFloat { style.gutterWidth + style.marks.barInset + 1.5 }
  private func rowMidY(_ line: Int) -> CGFloat {
    style.topInset + CGFloat(line - 1) * style.lineHeight + style.lineHeight / 2
  }

  /// 黒地の窓に載せた文書の面（装備の色は地との合成で読む）。
  private struct Hosted {
    let document: EditorDocument
    let ground: Ground
    let window: NSWindow
  }

  private func host(_ text: String, size: NSSize = NSSize(width: 400, height: 200)) throws
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
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    withExtendedLifetime(session) {}
    return Hosted(document: document, ground: ground, window: window)
  }

  private final class Ground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.black.setFill()
      bounds.fill()
    }
  }

  /// 描いて色を引く（flipped 座標。y は上から）。
  private func rgb(_ view: NSView, _ x: CGFloat, _ y: CGFloat) throws -> [Int] {
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    let color = try XCTUnwrap(
      rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
    return [color.redComponent, color.greenComponent, color.blueComponent].map { Int($0 * 255) }
  }

  private func isBlack(_ rgb: [Int]) -> Bool { rgb.allSatisfy { $0 <= 3 } }

  /// 1px の線は device pixel に揃えて描かれるので、x の前後 1 device pixel も見る。
  private func hasInk(_ view: NSView, _ x: CGFloat, _ y: CGFloat) throws -> Bool {
    try [x - 0.5, x, x + 0.5].contains { !isBlack(try rgb(view, $0, y)) }
  }
  private func isGreen(_ c: [Int]) -> Bool { !isBlack(c) && c[1] > c[0] && c[1] > c[2] }
  private func isBlue(_ c: [Int]) -> Bool { !isBlack(c) && c[2] > c[0] && c[2] > c[1] }
  private func isRed(_ c: [Int]) -> Bool { !isBlack(c) && c[0] > c[1] && c[0] > c[2] }

  /// 描き直しは layout の後に載るので、成立まで描いて測り直す。
  private func waitDrawn(
    _ condition: @escaping () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    pumpMain(until: { (try? condition()) ?? false }, timeout: 5, "描かれる", file: file, line: line)
  }

  // MARK: - ガターの印

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
    let swatch = Swatch(frame: NSRect(x: 0, y: 0, width: 20, height: 20), color: style.marks.added)
    let reference = NSWindow(
      contentRect: swatch.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    reference.appearance = NSAppearance(named: .darkAqua)
    reference.contentView = swatch
    let expected = try rgb(swatch, 10, 10)
    XCTAssertTrue(
      zip(bar, expected).allSatisfy { abs($0 - $1) <= 2 },
      "面の色は style の色（α 込み）そのまま: \(bar) ≈ \(expected)")
  }

  /// 黒地に style の色を塗った見本（合成の答えを同じ描画経路で取る）。
  private final class Swatch: NSView {
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
  /// 長い行で横スクロールが起き、印はガターに浮くので無事な一方、線・点・下線だけが置き去りになる壊れ方を守る。
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
    XCTAssertFalse(try hasInk(ground, guide, rowMidY(3)), "線は 3 桁ぶん左（ガターの下）へ動いて見えない")
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

  // MARK: - 本文の装備

  /// インデント線は行頭から段の単位ぶんの文字の左端に、段の数だけ立つ（単位は本文から検出）。空行は隣の浅い方。
  func testIndentGuidesStandAtTheUnitColumns() throws {
    let hosted = try host("f {\n  a\n    b\n\n    c\n  d\n}\n")
    let ground = hosted.ground
    let guide1 = bodyX + 2 * cell
    let guide2 = bodyX + 4 * cell
    waitDrawn { try self.hasInk(ground, guide1, self.rowMidY(2)) }
    XCTAssertTrue(try hasInk(ground, guide1, rowMidY(2)), "1 段の行に段 1 の線")
    XCTAssertFalse(try hasInk(ground, guide2, rowMidY(2)), "1 段の行に段 2 の線は無い")
    XCTAssertTrue(try hasInk(ground, guide1, rowMidY(3)))
    XCTAssertTrue(try hasInk(ground, guide2, rowMidY(3)), "2 段の行に段 2 の線")
    XCTAssertTrue(try hasInk(ground, guide2, rowMidY(4)), "空行は隣（2 段と 2 段）の浅い方＝2 段")
    XCTAssertFalse(try hasInk(ground, guide1, rowMidY(1)), "0 段の行には無い")
    XCTAssertFalse(try hasInk(ground, guide2 - 2, rowMidY(4)), "線の左は地（空行なので丸点も無い）")
    XCTAssertFalse(try hasInk(ground, guide2 + 2, rowMidY(4)), "線の右は地")
  }

  /// CRLF の文書でも段落末は行の外——行末の 1 個のスペースに点が出て、空行のインデント線が隣から続く
  /// （`"\r\n"` は Character 1 個なので、文字単位で改行を落とすと CR が残って両方消える）。
  func testCRLFParagraphsKeepTrailingSpaceDotsAndBlankLineGuides() throws {
    let hosted = try host("  a \r\n\r\n    b\r\n")
    let ground = hosted.ground
    let guide = bodyX + 2 * cell
    waitDrawn { try self.hasInk(ground, guide, self.rowMidY(3)) }
    XCTAssertFalse(isBlack(try rgb(ground, bodyX + 3.5 * cell, rowMidY(1))), "行末の 1 個に点")
    XCTAssertTrue(try hasInk(ground, guide, rowMidY(2)), "空行に隣の浅い方（1 段）の線")
  }

  /// 丸点は行頭・行末・2 個以上の連続スペースのセルの中央に出て、単語間の 1 個には出ない。
  func testWhitespaceDotsOnlyAtBoundaries() throws {
    let hosted = try host("a b  c \n")
    let ground = hosted.ground
    let center = { (index: Int) in self.bodyX + (CGFloat(index) + 0.5) * self.cell }
    XCTAssertTrue(isBlack(try rgb(ground, center(1), rowMidY(1))), "単語間の 1 個")
    XCTAssertFalse(isBlack(try rgb(ground, center(3), rowMidY(1))), "2 個以上の連続")
    XCTAssertFalse(isBlack(try rgb(ground, center(4), rowMidY(1))))
    XCTAssertFalse(isBlack(try rgb(ground, center(6), rowMidY(1))), "行末")
  }

  /// URL の下に、文字と同じ色の 1px の線が行の下部に連続して出る（字の隙間でも切れない）。
  func testLinkUnderlineRunsBelowTheURL() throws {
    let hosted = try host("// see https://a.b/c now\n")
    let ground = hosted.ground
    let x0 = bodyX + 7 * cell
    let x1 = bodyX + 20 * cell
    var underlineY: CGFloat?
    for y in stride(from: style.topInset + 10, to: style.topInset + style.lineHeight, by: 1) {
      let xs = stride(from: x0 + 0.5, to: x1, by: cell / 2)
      if try xs.allSatisfy({ !isBlack(try rgb(ground, $0, y)) }) {
        underlineY = y
        break
      }
    }
    XCTAssertNotNil(underlineY, "URL の幅いっぱいの連続した線")
    XCTAssertTrue(isBlack(try rgb(ground, x0 - cell / 2, try XCTUnwrap(underlineY))), "URL の前には無い")
    XCTAssertTrue(isBlack(try rgb(ground, x1 + cell / 2, try XCTUnwrap(underlineY))), "URL の後には無い")
  }

  // MARK: - ⌘クリック

  /// ⌘クリックだけが URL を渡し、素のクリックはキャレットを置く。URL の外の ⌘クリックは上流に落ちる。
  func testCommandClickOpensTheLinkAndPlainClickPlacesTheCaret() throws {
    let hosted = try host("see https://a.b/c\n")
    let document = hosted.document
    let window = hosted.window
    var opened: [URL] = []
    document.surface.onOpenLink = { opened.append($0) }
    let client = try XCTUnwrap(document.surface.responder as? NSTextInputClient)
    let onURL = document.surface.responder.convert(
      NSPoint(x: bodyX + 8 * cell, y: rowMidY(1) - style.topInset), to: nil)
    let offURL = document.surface.responder.convert(
      NSPoint(x: bodyX + 1 * cell, y: rowMidY(1) - style.topInset), to: nil)
    func click(_ point: NSPoint, _ flags: NSEvent.ModifierFlags) throws {
      let event = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
      document.surface.responder.mouseDown(with: event)
    }

    try click(onURL, [.command])
    XCTAssertEqual(opened.map(\.absoluteString), ["https://a.b/c"])

    try click(onURL, [])
    XCTAssertEqual(opened.count, 1, "素のクリックは開かない")
    XCTAssertTrue(
      (7...9).contains(client.selectedRange().location), "キャレットが置かれる: \(client.selectedRange())")

    try click(offURL, [.command])
    XCTAssertEqual(opened.count, 1, "URL の外の ⌘クリックは開かない")
    XCTAssertTrue((0...2).contains(client.selectedRange().location), "上流へ落ちてキャレットが動く")
  }
}

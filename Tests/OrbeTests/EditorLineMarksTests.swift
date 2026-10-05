import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// セッションが開いた本物のテキスト面に載る行の装備——丸点が横スクロールに付いてくる、外部変更の差し替えでタブ幅が
/// 決め直される、⌘クリックだけが URL を開いて素のクリックはキャレットを置く。位置は画素で見る。
///
/// 壊れると何が起きるか。長い行を横へ送ると点が置き去りになる。差し替えた後もタブが前の幅で並ぶ。⌘クリックが
/// 選択と衝突して URL が開かないか、素のクリックで勝手にブラウザが開く。
@MainActor
final class EditorLineMarksTests: OrbeTestCase {
  let style = EditorStyle.make()
  var cell: CGFloat { (" " as NSString).size(withAttributes: [.font: style.font]).width }
  /// 本文の左端（行番号 50 ＋ 印の列 19）。
  var bodyX: CGFloat { style.gutterWidth + style.marks.gutterWidth }
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
    let document = try session.open(url, as: .pinned)
    let ground = Ground(frame: NSRect(origin: .zero, size: size))
    document.surface.view.frame = ground.bounds
    ground.addSubview(document.surface.view)
    let window = NSWindow(
      contentRect: ground.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = ground
    ground.layoutSubtreeIfNeeded()
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    // 本文の最初の行が描かれるまで待つ（固定で眠らない）。
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

  /// 描き直しは layout の後に載るので、成立まで描いて測り直す。
  func waitDrawn(
    _ condition: @escaping () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    pumpMain(until: { (try? condition()) ?? false }, timeout: 5, "描かれる", file: file, line: line)
  }

  /// 横にスクロールしても本文の装備は行に付いてくる。長い行で横スクロールが起き、印は行番号の列にあるので無事な
  /// 一方、点だけが置き去りになる壊れ方を守る。
  func testDecorationsFollowHorizontalScrolling() throws {
    let long = String(repeating: "x", count: 100) + "  " + String(repeating: "x", count: 100)
    let hosted = try host("a\n  b  c \(long)\n")
    let ground = hosted.ground
    let document = hosted.document
    let surface = try engine(document)
    let dot = bodyX + 3.5 * cell
    waitDrawn { !self.isBlack(try self.rgb(ground, dot, self.rowMidY(2))) }

    let shift = 3 * cell
    surface.scroll(toX: shift)
    XCTAssertEqual(surface.scrollPosition.x, shift, accuracy: 1e-9, "前提: 横の範囲が測られていて、3 桁送れた")
    // 送った後の絵だけが満たす: 3 桁目の点は 0 桁目の位置へ来て、元の位置は空く（送る前は両方に点がある）。
    waitDrawn {
      try !self.isBlack(self.rgb(ground, dot - shift, self.rowMidY(2)))
        && self.isBlack(self.rgb(ground, dot, self.rowMidY(2)))
    }

    // 100 桁右へ: 1 画面ぶん先の連続スペース（107 桁目）の点が、可視矩形の中に描かれる。
    surface.scroll(toX: 100 * cell)
    waitDrawn { !self.isBlack(try self.rgb(ground, self.bodyX + 7.5 * self.cell, self.rowMidY(2))) }
    XCTAssertTrue(isBlack(try rgb(ground, dot, rowMidY(1))), "短い行の右は地")
    surface.scroll(toX: 0)
    waitDrawn { !self.isBlack(try self.rgb(ground, dot, self.rowMidY(2))) }
  }

}

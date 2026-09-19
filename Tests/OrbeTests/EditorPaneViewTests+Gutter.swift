import AppKit
import XCTest

@testable import Orbe

/// 面の地とガター——横スクロールで本文がガターの下を通っても透けず、ガターの地は面の地と同じ濃度で（透過設定の
/// veil が二重にならない）、設定が変われば追従する。
///
/// 壊れると何が起きるか。長い行を右へ送ると行番号と本文の字が重なって読めない。透過設定でガターだけ濃い帯に
/// 見える。
@MainActor
final class EditorPaneViewGutterTests: OrbeTestCase {
  private let style = EditorStyle.make()

  /// 面を描いて 1 点の色（alpha 込み・0…255）を引く。
  private func rgba(_ pane: EditorPaneView, _ x: CGFloat, _ y: CGFloat) throws -> [Int] {
    let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
    pane.cacheDisplay(in: pane.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / pane.bounds.width
    let c = try XCTUnwrap(
      rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map {
      Int($0 * 255)
    }
  }

  private func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }

  func testGutterHidesTheTextScrolledUnderItAndSharesThePaneGround() throws {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: 700)
    window.appearance = NSAppearance(named: .darkAqua)
    defer { window.orderOut(nil) }
    let line = String(repeating: "0123456789", count: 30)
    let document = try tab.editor.open(try caseFile("long.txt", "\(line)\n\(line)\n"))
    pane.layoutSubtreeIfNeeded()
    let surface = document.surface.view
    let origin = pane.convert(surface.bounds, from: surface).origin
    let gutter = style.gutterWidth + style.marks.gutterWidth
    let rowY = origin.y + style.topInset + style.lineHeight / 2
    let firstGlyph = origin.x + gutter + 3
    /// ガターの列（左端から印の列の右端まで）の色の並び。
    func gutterRow() throws -> [[Int]] {
      try stride(from: origin.x + 1, to: origin.x + gutter - 1, by: 1).map {
        try rgba(pane, $0, rowY)
      }
    }
    /// 面の地: 本文の下の空き（文書より下）と、面の外（パンくずの帯の下）。
    func bodyGround() throws -> [Int] {
      try rgba(pane, origin.x + gutter + 40, origin.y + 6 * style.lineHeight)
    }
    func markColumn() throws -> [Int] { try rgba(pane, origin.x + gutter - 5, rowY) }

    pumpMain(
      until: { (try? self.same(try self.rgba(pane, firstGlyph, rowY), try bodyGround())) == false },
      "本文が描かれる")
    let opaqueRow = try gutterRow()
    XCTAssertTrue(same(try markColumn(), try bodyGround()), "印の列は面の地の色")
    XCTAssertEqual(try bodyGround()[3], 255, "不透明")

    let scroll = try XCTUnwrap(surface.subviews.first as? NSScrollView)
    let glyphBefore = try rgba(pane, firstGlyph, rowY)
    scroll.contentView.scroll(to: NSPoint(x: 37 * 7.4, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    pumpMain(
      until: { (try? self.same(try self.rgba(pane, firstGlyph, rowY), glyphBefore)) == false },
      "横スクロールで本文が動く")
    XCTAssertEqual(try gutterRow(), opaqueRow, "本文がガターの下を通っても、ガターの画素は変わらない")

    // 透過の veil は本文を隠し切らない（濃度ぶんだけ透ける）ので、地の比較は本文をガターの下から戻してから。
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    pumpMain(
      until: { (try? self.same(try self.rgba(pane, firstGlyph, rowY), glyphBefore)) == true },
      "本文が戻る")
    pane.configure(
      translucency: ChromeTranslucency(effectiveOpacity: 0.5, translucent: true, blur: false),
      localization: LocalizationStore(language: .systemDefault), fontResolver: ChromeFontResolver(),
      sidebar: pane.sidebar)
    pumpMain(until: { (try? bodyGround()[3]) ?? 255 < 200 }, "透過の veil になる")
    XCTAssertEqual(try bodyGround()[3], 128, accuracy: 3, "面の地は effectiveOpacity")
    XCTAssertTrue(same(try markColumn(), try bodyGround()), "ガターの地は面の地と同じ濃度（veil が二重にならない）")
    XCTAssertTrue(
      same(try rgba(pane, origin.x + 30, origin.y + 6 * style.lineHeight), try bodyGround()),
      "文書より下のガターの列も同じ地")
    XCTAssertTrue(
      same(try rgba(pane, origin.x + gutter + 40, origin.y + 1), try bodyGround()), "上端の余白も同じ地")
  }
}

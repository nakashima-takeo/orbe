import AppKit
import XCTest

@testable import Orbe

/// 面の地と行番号の列——地は pane が全面を 1 層で塗り、面は地を持たない。行番号の列は本文の横に並び、横スクロールで
/// 本文がその下をくぐらない。列の地も本体の地と同じ濃度で（透過設定の veil が二重にならない）、文書の出入り・
/// サイドバーの幅・透過設定の変化に層が追従する。
///
/// 画素は `cacheDisplay` ではなく、`needsDisplay` を立てずに描いた層（`displayIfNeeded` の後の layer）から
/// 読む——立て忘れは cacheDisplay では見えない。
///
/// 壊れると何が起きるか。長い行を右へ送ると行番号と本文の字が重なって読めない（透過設定では下の本文が透ける）。
/// 透過設定でタブを作って最初のファイルを開くと本体だけ濃い地になり、サイドバーを引くと地の抜けた帯や二重の帯が出る。
@MainActor
final class EditorPaneViewGutterTests: OrbeTestCase {
  private let style = EditorStyle.make()

  /// 層の 1 枚の写し（描き直さない）。色は alpha 込み・0…255。
  private struct Layer {
    private let rep: NSBitmapImageRep
    private static let scale: CGFloat = 2

    init(_ pane: EditorPaneView) throws {
      pane.displayIfNeeded()
      let size = pane.bounds.size
      rep = try XCTUnwrap(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width * Self.scale),
          pixelsHigh: Int(size.height * Self.scale), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0))
      let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
      context.translateBy(x: 0, y: size.height * Self.scale)
      context.scaleBy(x: Self.scale, y: -Self.scale)
      try XCTUnwrap(pane.layer).render(in: context)
    }

    /// premultiplied の生の値（地の比較には十分）。y は上から。
    func rgba(_ x: CGFloat, _ y: CGFloat) throws -> [Int] {
      let data = try XCTUnwrap(rep.bitmapData)
      let offset = Int(y * Self.scale) * rep.bytesPerRow + Int(x * Self.scale) * 4
      return (0..<4).map { Int(data[offset + $0]) }
    }
  }

  private func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }

  /// 層を写して条件が成立するまで待つ（描き直しは runloop で来る）。
  private func layer(
    of pane: EditorPaneView, until ready: (Layer) throws -> Bool, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> Layer {
    let deadline = Date().addingTimeInterval(5)
    var layer = try Layer(pane)
    while try !ready(layer), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      layer = try Layer(pane)
    }
    XCTAssertTrue(try ready(layer), "5 秒以内に成立しない: \(message)", file: file, line: line)
    return layer
  }

  private var gutter: CGFloat { style.gutterWidth + style.marks.gutterWidth }

  /// 横スクロールしても本文は行番号の列の下をくぐらず、列の画素は 1 つも変わらない。
  func testTheTextScrolledRightStaysOutOfTheLineNumbers() throws {
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
    let rowY = origin.y + style.topInset + style.lineHeight / 2
    let firstGlyph = origin.x + gutter + 3
    func gutterRow(_ layer: Layer) throws -> [[Int]] {
      try stride(from: origin.x + 1, to: origin.x + gutter - 1, by: 1).map {
        try layer.rgba($0, rowY)
      }
    }
    func ground(_ layer: Layer) throws -> [Int] {
      try layer.rgba(origin.x + gutter + 40, origin.y + 6 * style.lineHeight)
    }
    let before = try layer(
      of: pane, until: { try !self.same(try $0.rgba(firstGlyph, rowY), try ground($0)) }, "本文が描かれる")
    let opaqueRow = try gutterRow(before)
    XCTAssertTrue(
      same(try before.rgba(origin.x + gutter - 5, rowY), try ground(before)), "印の列は面の地の色")
    XCTAssertEqual(try ground(before)[3], 255, "不透明")

    let scroll = try XCTUnwrap(surface.subviews.first as? NSScrollView)
    let glyphBefore = try before.rgba(firstGlyph, rowY)
    let cell = (" " as NSString).size(withAttributes: [.font: style.font]).width
    scroll.contentView.scroll(to: NSPoint(x: 37 * cell, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    // 描き直しは runloop で来るので、本文が動いて列の画素が元どおりになるまで待つ（本文が列に入れば戻らない）。
    let after = try layer(
      of: pane,
      until: {
        try !self.same(try $0.rgba(firstGlyph, rowY), glyphBefore) && gutterRow($0) == opaqueRow
      },
      "横スクロールで本文が動き、列の画素は変わらない")
    let afterRow = try gutterRow(after)
    XCTAssertEqual(afterRow, opaqueRow, "本文は列の下をくぐらず、列の画素は変わらない")
  }

  /// 透過設定のタブで、最初の文書を開く・サイドバーを引く・文書を閉じる、のどれでも地は 1 枚（二重にも空にも
  /// ならない）で、行番号の列（行の中・上端の余白・文書の直下・文書より下）も本体の地と同じ濃度。
  func testGroundStaysSingleLayeredAsTheBodyRectMoves() throws {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.view.editor
    pane.configure(
      translucency: ChromeTranslucency(effectiveOpacity: 0.5, translucent: true, blur: false),
      localization: LocalizationStore(language: .systemDefault), fontResolver: ChromeFontResolver(),
      sidebar: pane.sidebar)
    let window = hostEditor(tab, width: 700)
    window.appearance = NSAppearance(named: .darkAqua)
    defer { window.orderOut(nil) }
    let veil = 128
    let center = pane.bodyRect
    let empty = try layer(
      of: pane, until: { try $0.rgba(center.midX, center.midY)[3] == veil }, "空状態の地")
    _ = empty

    let document = try tab.editor.open(try caseFile("a.txt", "abc\nabc\n"))
    pane.layoutSubtreeIfNeeded()
    let surface = document.surface.view
    let origin = pane.convert(surface.bounds, from: surface).origin
    let rowY = origin.y + style.topInset + style.lineHeight / 2
    let below = origin.y + 6 * style.lineHeight
    let opened = try layer(
      of: pane, until: { try $0.rgba(origin.x + gutter + 40, below)[3] == veil },
      "最初の文書を開いても本体の地は 1 枚（二重なら 192）")
    let ground = try opened.rgba(origin.x + gutter + 40, below)
    XCTAssertTrue(same(try opened.rgba(origin.x + gutter - 5, rowY), ground), "印の列（行の中）")
    XCTAssertTrue(same(try opened.rgba(origin.x + 30, origin.y + 1), ground), "列の上端の余白")
    XCTAssertTrue(
      same(
        try opened.rgba(origin.x + 30, origin.y + style.topInset + 2 * style.lineHeight + 2), ground
      ),
      "文書の直下の列")
    XCTAssertTrue(same(try opened.rgba(origin.x + 30, below), ground), "文書より下の列")
    XCTAssertTrue(same(try opened.rgba(origin.x + gutter + 40, origin.y + 1), ground), "本体の上端の余白")

    // サイドバーを広げると帯はサイドバーの地（沈み面 + veil）になり、戻すと本体の地（veil 1 枚）に戻る。
    let shown = pane.shownSidebarWidth
    let band = origin.x + 20
    pane.resizeSidebar(to: shown + 40)
    let widened = try layer(
      of: pane,
      until: { try self.same(try $0.rgba(band, below), try $0.rgba(origin.x - 100, below)) },
      "広げた帯はサイドバーの地（pane の地が抜けていれば薄い）")
    _ = widened
    pane.resizeSidebar(to: shown)
    let narrowed = try layer(
      of: pane, until: { try $0.rgba(band, below)[3] == veil }, "戻した帯は本体の地 1 枚（二重なら 192）")
    _ = narrowed

    tab.editor.close(document)
    let closed = try layer(
      of: pane, until: { try $0.rgba(center.midX, center.midY)[3] == veil }, "閉じても地は 1 枚")
    _ = closed
  }
}

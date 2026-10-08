import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 区画の絵を描く材料に写す——字の連なりの色・余白、画像の上限と覚え、箱の影の届く所、入力欄のキャレット。壊れると、
/// 同じ字体で色を分けた字が 1 色になる・インラインコードの地が字からずれる・大きな画像が黙って消える・描かなくなった画像が
/// 面の寿命まで残る・スレッドの影が本文の左端で切れる・返信欄のキャレットが見えない。
extension SurfaceZonesTests {
  private static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
  private static let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

  private func material(_ surface: MetalTextSurface, _ zone: SurfaceZone) throws -> ZoneMaterial {
    try XCTUnwrap(surface.zones[ObjectIdentifier(zone)]).material
  }

  /// 同じ字体で隣り合う字の連なりも、それぞれの色で描く（選べる字の行の見え方も同じ）。
  func testRunsOfOneFontInTwoColorsKeepTheirColors() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let font = NSFont.systemFont(ofSize: 12)
    let zone = PictureZone { _ in
      ZonePicture(
        height: 40,
        elements: [
          .text(
            ZoneTextLine(
              origin: CGPoint(x: 0, y: 14),
              runs: [
                ZoneTextRun("red", font: font, color: Self.red),
                ZoneTextRun("green", font: font, color: Self.green),
              ])),
          .selectable(
            ZoneSelectableLine(
              origin: CGPoint(x: 0, y: 32), text: "t", range: NSRange(location: 0, length: 8),
              styles: [
                ZoneTextStyle(length: 3, font: font, color: Self.red),
                ZoneTextStyle(length: 5, font: font, color: Self.green),
              ])),
        ], texts: [ZoneText(id: "t", string: "redgreen")])
    }
    surface.setRows(self.zone(zone, at: 2))
    let look = { (color: NSColor) in
      InkColor(
        color, appearance: surface.textView.effectiveAppearance, space: surface.space,
        scale: surface.scale)
    }
    let runs = try material(surface, zone).runs
    XCTAssertEqual(
      runs.map(\.ink), [look(Self.red), look(Self.green), look(Self.red), look(Self.green)])
    XCTAssertEqual(runs.map(\.glyphs.count), [3, 5, 3, 5])
  }

  /// 選べる字の行の余白は、行頭の見え方なら字を右へ寄せ（当たりの行の左端も）、行の途中なら前後の字を押し出す。
  func testPaddingPushesTheTextOfASelectableLine() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let font = NSFont.systemFont(ofSize: 12)
    let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let picture = { (padding: CGFloat) in
      PictureZone { _ in
        ZonePicture(
          height: 30,
          elements: [
            .selectable(
              ZoneSelectableLine(
                origin: CGPoint(x: 10, y: 14), text: "t", range: NSRange(location: 0, length: 10),
                styles: [
                  ZoneTextStyle(length: 4, font: mono, color: Self.red, padding: padding),
                  ZoneTextStyle(length: 6, font: font, color: Self.green),
                ]))
          ], texts: [ZoneText(id: "t", string: "code after")])
      }
    }
    let plain = picture(0)
    surface.setRows(zone(plain, at: 2))
    let bare = try material(surface, plain)
    let padded = picture(4)
    surface.setRows(zone(padded, at: 2))
    let pushed = try material(surface, padded)
    let first = { (material: ZoneMaterial, ink: NSColor) -> Float in
      material.runs.first {
        $0.ink.color
          == FrameColor(ink, appearance: surface.textView.effectiveAppearance, space: surface.space)
      }?.xs[0] ?? -1
    }
    XCTAssertEqual(first(pushed, Self.red), first(bare, Self.red) + 4, accuracy: 1e-4, "行頭の余白で右へ")
    XCTAssertEqual(
      first(pushed, Self.green), first(bare, Self.green) + 8, accuracy: 1e-4, "後ろの字は両側の余白の分")
    let line = try XCTUnwrap(surface.zones[ObjectIdentifier(padded)]?.hits.lines.first)
    XCTAssertEqual(line.origin.x, 14, "当たりの行の左端も余白の分")
  }
}

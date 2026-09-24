import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 俯瞰（ミニマップ・スクロールバー・影）と出現の強調のテストが共有する足場——本物のテキスト面を載せた pane を
/// 窓に置き、view 1 枚を透明な地に描いて画素を読む。
@MainActor
struct OverviewHost {
  let tab: TerminalTab
  let pane: EditorPaneView
  let document: EditorDocument
  let window: NSWindow

  var scroll: NSScrollView { document.surface.responder.enclosingScrollView! }

  /// 先頭に見えている行（小数）。
  var firstLine: CGFloat { document.viewportLines.first }
}

@MainActor
extension OrbeTestCase {
  /// `colored` は色付けの queries を注入する（役割の色を本物の構文木で見るときだけ）。
  func hostOverview(
    _ text: String, width: CGFloat = 700, height: CGFloat = 400,
    name: String = "o-\(UUID().uuidString).txt", colored: Bool = false
  ) throws -> OverviewHost {
    let queries = colored ? Bundle(for: Self.self).bundleURL.deletingLastPathComponent() : nil
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: queries))
    let pane = tab.view.editor
    let window = hostEditor(tab, width: width, height: height)
    window.appearance = NSAppearance(named: .darkAqua)
    addTeardownBlock { MainActor.assumeIsolated { window.orderOut(nil) } }
    let document = try tab.editor.open(try caseFile(name, text))
    pane.layoutSubtreeIfNeeded()
    pumpMain(until: { document.surface.viewport.visibleLines > 0 }, "viewport が出る")
    return OverviewHost(tab: tab, pane: pane, document: document, window: window)
  }

  /// n 行（末尾の改行で索引は n + 1 行になる）。
  func numberedLines(_ n: Int) -> String { (1...n).map { "line \($0)\n" }.joined() }
}

extension NSView {
  /// tracking area `area` の出入りの出来事（`trackingArea` がその area を指す）。
  func enterExitEvent(_ type: NSEvent.EventType, area: NSTrackingArea?) -> NSEvent {
    NSEvent.enterExitEvent(
      with: type, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
      trackingNumber: area.map { unsafeBitCast($0, to: Int.self) } ?? 0, userData: nil)!
  }
}

/// view を 1 回描いて画素を読む（同じ描画から何か所も読む）。座標は view の pt、y は上から。
@MainActor
struct ViewPixels {
  let rep: NSBitmapImageRep
  let scale: CGFloat

  init(_ view: NSView) throws {
    rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    scale = CGFloat(rep.pixelsWide) / view.bounds.width
  }

  func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
    rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear
  }

  /// 矩形の中の画素の α の最大と合計（0…1）。
  func alpha(in rect: NSRect) -> (max: CGFloat, sum: CGFloat) {
    var peak: CGFloat = 0
    var sum: CGFloat = 0
    for py in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
      for px in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
        let a = rep.colorAt(x: px, y: py)?.alphaComponent ?? 0
        peak = max(peak, a)
        sum += a
      }
    }
    return (peak, sum)
  }

  /// 矩形の中で最も α の高い画素の色（字の色を読む）。
  func strongest(in rect: NSRect) -> NSColor {
    var result = NSColor.clear
    for py in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
      for px in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
        let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) ?? .clear
        if c.alphaComponent > result.alphaComponent { result = c }
      }
    }
    return result
  }
}

/// 色の見分け（git の印・一致の地）。
enum Hue {
  static func green(_ c: NSColor) -> Bool {
    c.greenComponent > c.redComponent && c.greenComponent > c.blueComponent
  }
  static func blue(_ c: NSColor) -> Bool {
    c.blueComponent > c.redComponent && c.blueComponent > c.greenComponent
  }
  static func red(_ c: NSColor) -> Bool {
    c.redComponent > c.greenComponent && c.redComponent > c.blueComponent
  }
  /// 検索の一致の橙（赤が勝ち、青が赤よりずっと少ない）。
  static func orange(_ c: NSColor) -> Bool {
    c.alphaComponent > 0.1 && c.redComponent > c.greenComponent
      && c.redComponent > c.blueComponent + 0.3
  }
}

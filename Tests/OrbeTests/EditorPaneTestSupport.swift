import AppKit
import XCTest

@testable import Orbe

/// エディター面の pane を窓に載せて調べるテストの共通の足場。
extension OrbeTestCase {
  /// このテストの隔離ディレクトリにファイルを作る。
  func caseFile(_ name: String, _ text: String) throws -> URL {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  /// タブを幅 `width` のエディター全面（＋背）の窓に載せる。
  func hostEditor(_ tab: TerminalTab, width: CGFloat, height: CGFloat = 400) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width + FaceGeometry.spine, height: height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    tab.view.layoutSubtreeIfNeeded()
    return window
  }

  /// 面の座標 x（y は中ほど）を窓座標へ。
  func panePoint(_ pane: EditorPaneView, _ x: CGFloat) -> NSPoint {
    pane.convert(NSPoint(x: x, y: 200), to: nil)
  }

  /// 面を描いて測る。`ready` が成立するまで描き直す（SwiftUI の描画コミットに固定で眠らない）。成立しなければ
  /// 最後の測定を返し、呼び手の assert が落ちる。
  func probe(_ pane: EditorPaneView, until ready: (PaneProbe) throws -> Bool) throws -> PaneProbe {
    let deadline = Date().addingTimeInterval(5)
    var probe = try PaneProbe(pane)
    while try !ready(probe), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      probe = try PaneProbe(pane)
    }
    return probe
  }

  /// 配下の最初の NSScrollView（SwiftUI の ScrollView の裏）。
  func scrollView(in view: NSView) -> NSScrollView? {
    for subview in view.subviews {
      if let scroll = subview as? NSScrollView { return scroll }
      if let scroll = scrollView(in: subview) { return scroll }
    }
    return nil
  }
}

/// 面の描画 1 枚。色を x, y で引く（y 省略はツリーの下の空き＝根の行より下）。
struct PaneProbe {
  let rep: NSBitmapImageRep
  let scale: CGFloat
  private let bottom: CGFloat

  init(_ pane: EditorPaneView) throws {
    rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
    pane.cacheDisplay(in: pane.bounds, to: rep)
    scale = CGFloat(rep.pixelsWide) / pane.bounds.width
    bottom = pane.bounds.height - 12
  }

  func rgb(_ x: CGFloat, y: CGFloat? = nil) throws -> [Int] {
    let c = try XCTUnwrap(
      rep.colorAt(x: Int(x * scale), y: Int((y ?? bottom) * scale))?.usingColorSpace(.deviceRGB))
    return [c.redComponent, c.greenComponent, c.blueComponent].map { Int($0 * 255) }
  }

  static func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }
}

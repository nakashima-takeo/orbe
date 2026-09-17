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
  func hostEditor(_ tab: TerminalTab, width: CGFloat) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width + FaceGeometry.spine, height: 400),
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
}

import AppKit
import OrbeEditorCore
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// エディター面の pane を窓に載せて調べるテストの共通の足場。
extension OrbeTestCase {
  /// このテストの隔離ディレクトリにファイルを作る。
  func caseFile(_ name: String, _ text: String) throws -> URL {
    let dir = TestScratch.caseDir
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

  /// 文書の本文。テキスト面（エンジン）の本文を入力の口（`NSTextInputClient`）から読み、文書の写しと UTF-16 の単位で
  /// 一致すること（片割れのサロゲートも含めて）を確かめてから返す——製品の契約に本文を読む口は無いので、写しが面を
  /// 追えているかはテストがエンジンから読んで見る。
  @MainActor
  func bodyText(
    _ document: EditorDocument, file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let engine = engineUnits(document)
    XCTAssertEqual(
      Array(document.text.contiguousUnits()), engine, "文書の写しが面の本文と違う", file: file, line: line)
    return String(decoding: engine, as: UTF16.self)
  }

  /// テキスト面（エンジン）の本文の UTF-16 の単位。
  @MainActor
  func engineUnits(_ document: EditorDocument) -> [UInt16] {
    let client = document.surface.responder as? NSTextInputClient
    guard
      let engine = client?.attributedSubstring(
        forProposedRange: NSRange(location: 0, length: Int(Int32.max)), actualRange: nil)?.string
        as NSString?
    else { return [] }
    var units = [UInt16](repeating: 0, count: engine.length)
    engine.getCharacters(&units, range: NSRange(location: 0, length: engine.length))
    return units
  }

  /// 文書の裏の仕事（構文・行差分・検索・出現）が今の版に追いつき、結果を受け取るまで待つ（受け取り箱を見て待つ。時間では
  /// 待たない）。
  @MainActor
  func catchUp(_ document: EditorDocument, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(document.waitUntilCaughtUp(), "裏の仕事が追いつかない", file: file, line: line)
  }

  /// pane が見せている文書の裏の仕事が追いつくのを待つ（→ `catchUp(_:)`）。
  @MainActor
  func catchUp(_ pane: EditorPaneView, file: StaticString = #filePath, line: UInt = #line) {
    guard let document = pane.document else { return }
    catchUp(document, file: file, line: line)
  }

  /// 面の座標 x（y は中ほど）を窓座標へ。
  func panePoint(_ pane: EditorPaneView, _ x: CGFloat) -> NSPoint {
    pane.convert(NSPoint(x: x, y: 200), to: nil)
  }

  /// 面を描いて測る。`ready` が成立するまで描き直す（SwiftUI の描画コミットに固定で眠らない）。成立しなければ
  /// 最後の測定を返し、この場で落ちる。
  func probe(
    _ pane: EditorPaneView, file: StaticString = #filePath, line: UInt = #line,
    until ready: (PaneProbe) throws -> Bool
  ) throws -> PaneProbe {
    let deadline = Date().addingTimeInterval(5)
    var probe = try PaneProbe(pane)
    while try !ready(probe), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      probe = try PaneProbe(pane)
    }
    XCTAssertTrue(try ready(probe), "5 秒以内に成立しない", file: file, line: line)
    return probe
  }

  /// 行内入力の入力欄（field editor）が焦点を取るまで待って返す。
  func inputField(_ pane: EditorPaneView, in window: NSWindow) throws -> NSTextView {
    pumpMain(
      until: { (window.firstResponder as? NSView)?.isDescendant(of: pane.sideHost) == true },
      "入力欄が焦点を取る")
    return try XCTUnwrap(window.firstResponder as? NSTextView)
  }

  /// ファイルタブ `index` の右端の枠（× / ●）の中心（面の座標）。タブの幅は同じ view を単独で組んで測る。
  @MainActor
  func fileTabSlotCenter(_ pane: EditorPaneView, _ index: Int) -> NSPoint {
    let right = pane.shell.tabs.prefix(index + 1).reduce(pane.headerHost.frame.minX) { x, tab in
      x + NSHostingView(rootView: FileTabView(tab: tab, shell: pane.shell)).fittingSize.width
    }
    return NSPoint(
      x: right - Theme.Layout.editorFileTabTrailing - Theme.Layout.editorTabClose / 2,
      y: Theme.Layout.editorFileTabs / 2)
  }

  /// ポインタを列の頭の上の点（面の座標）へ動かす。SwiftUI の onHover はポインタの下の view が受ける
  /// mouseEntered / mouseMoved で動く。
  @MainActor
  func movePointer(_ pane: EditorPaneView, to point: NSPoint) {
    let host = pane.headerHost
    let local = host.convert(point, from: pane)
    guard let target = host.hitTest(host.convert(local, to: host.superview)) else { return }
    let event = timedMouse(.mouseMoved, at: pane.convert(point, to: nil), in: pane.window)
    target.mouseExited(with: event)
    target.mouseEntered(with: event)
    target.mouseMoved(with: event)
  }

  /// 面の座標の点を押して離す（窓は ordered-in であること——`sendEvent` はそれ以外に配送しない）。アプリの配送の口
  /// （`NSApp.sendEvent`）から送るので、ローカルのイベントの監視も本物と同じく見る。`count` は何回目の押下か（2 なら
  /// ダブルクリックの 2 回目）。
  @MainActor
  func click(_ pane: EditorPaneView, at point: NSPoint, count: Int = 1) throws {
    let window = try XCTUnwrap(pane.window)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      NSApp.sendEvent(
        timedMouse(type, at: pane.convert(point, to: nil), in: window, clickCount: count))
    }
  }

  /// 今の時刻を持つマウスのイベント（SwiftUI のジェスチャーとホバーは時刻 0 のイベントを取りこぼす）。
  private func timedMouse(
    _ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow?, clickCount: Int = 1
  ) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: location, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
      context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
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

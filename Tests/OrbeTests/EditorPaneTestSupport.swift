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

  /// タブの器を幅 `width` の窓に載せ、エディターを開く（→ `mountEditor`）。足場が持つのは窓だけで、窓はテストの終わりまで
  /// 残る。タブは呼び出し元が持つので、窓はタブより後まで残る。タブを手放した後もランループを回すテストは、タブもテストの
  /// 終わりまで持つこと。持たないと、窓に載ったままの面が、タブへの参照（`EditorPaneView.group`。弱い参照）を失ったまま
  /// 根のサービス（ファイルの監視と git）を保持し続け、ランループが回ると監視の通知を受けて動作する。本番には無いこの状態での
  /// 動作に、テストの結果が左右される。
  @discardableResult
  func hostEditor(_ tab: TerminalTab, width: CGFloat, height: CGFloat = 400) -> NSWindow {
    holdUntilTestEnds(mountEditor(tab, width: width, height: height))
  }

  /// タブの器を幅 `width` の窓に載せ、エディターを開く。窓はテスト用の `OrbeWindowFake` で、確認のシートを画面に出さない。
  /// 窓をテストに預けないので、寿命は呼び出し元が決める。呼ぶのは、窓の解放そのものを確かめるテストと、計測の区間ごとに
  /// 窓を手放す性能計測だけ（ほかは `hostEditor`）。
  func mountEditor(_ tab: TerminalTab, width: CGFloat, height: CGFloat = 400) -> NSWindow {
    let window = OrbeWindowFake(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = tab.group.view
    tab.group.view.show(.editor, animated: false)
    tab.group.view.layoutSubtreeIfNeeded()
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
    var probe: PaneProbe?
    let settled = try waitUntil(5) {
      let measured = try PaneProbe(pane)
      probe = measured
      return try ready(measured)
    }
    XCTAssertTrue(settled, "5 秒以内に成立しない", file: file, line: line)
    return try XCTUnwrap(probe)
  }

  /// 行内入力の入力欄（field editor）が焦点を取るまで待って返す。
  func inputField(_ pane: EditorPaneView, in window: NSWindow) throws -> NSTextView {
    pumpMain(
      until: { (window.firstResponder as? NSView)?.isDescendant(of: pane.sideHost) == true },
      "入力欄が焦点を取る")
    return try XCTUnwrap(window.firstResponder as? NSTextView)
  }

  /// ポインタを面の座標の点へ動かす（`host` はその点の上の SwiftUI の器）。SwiftUI の onHover は
  /// ポインタの下の view が受ける mouseEntered / mouseMoved で動く。点の下に view が無ければ、呼んだ行で失敗を記録する。
  @MainActor
  func movePointer(
    _ pane: EditorPaneView, to point: NSPoint, over host: NSView,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let local = host.convert(point, from: pane)
    guard let target = host.hitTest(host.convert(local, to: host.superview)) else {
      XCTFail("ポインタを動かす点 \(point) の下に view が無い", file: file, line: line)
      return
    }
    let event = timedMouse(.mouseMoved, at: pane.convert(point, to: nil), in: pane.window)
    target.mouseExited(with: event)
    target.mouseEntered(with: event)
    target.mouseMoved(with: event)
  }

  /// ポインタを面の座標の点 `point`（`host` の上）から面の外へ出す。点の下に view が無ければ、呼んだ行で失敗を記録する。
  @MainActor
  func movePointerOut(
    _ pane: EditorPaneView, from point: NSPoint, over host: NSView,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let local = host.convert(point, from: pane)
    guard let target = host.hitTest(host.convert(local, to: host.superview)) else {
      XCTFail("ポインタを出す点 \(point) の下に view が無い", file: file, line: line)
      return
    }
    target.mouseExited(with: timedMouse(.mouseMoved, at: NSPoint(x: -10, y: -10), in: pane.window))
  }

  /// ツリーのつまみの矩形（窓の座標）。本番のつまみと同じく、ツリーの今の位置から、一覧の右端・全高のトラックに置く。
  @MainActor
  func treeThumbFrame(_ pane: EditorPaneView) -> NSRect? {
    guard let tree = scrollView(in: pane.sideHost), let document = tree.documentView else {
      return nil
    }
    let visible = tree.documentVisibleRect
    let geometry = SidebarScrollbar.Metrics(
      position: visible.minY, total: document.frame.height, visible: visible.height
    ).geometry
    let width = Theme.Layout.editorSidebarScrollbar
    return tree.convert(
      NSRect(
        x: tree.bounds.maxX - width, y: geometry.sliderPosition, width: width,
        height: geometry.sliderLength), to: nil)
  }

  /// 面の座標の点を押して離す（窓は `placeOffscreen` で並べておくこと——`sendEvent` は並んでいない窓に配送しない）。
  /// アプリの配送の口（`NSApp.sendEvent`）から送るので、ローカルのイベントの監視も本物と同じく見る。`count` は何回目の
  /// 押下か（2 ならダブルクリックの 2 回目）。
  @MainActor
  func click(_ pane: EditorPaneView, at point: NSPoint, count: Int = 1) throws {
    let window = try XCTUnwrap(pane.window)
    guard window.isVisible else {
      return XCTFail("マウスは並んだ窓にしか届かない。先に placeOffscreen で並べる")
    }
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

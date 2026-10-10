import SwiftUI
import XCTest

@testable import Orbe

/// ボード入りのタブ行の横スクロール。選択が右端のタブへ移るとタブ列だけがスクロールし、ボードのセルは左端に残る。
/// スクロール位置は描画を跨いで持つ状態なので、1 枚の host を使い回して選択を変えるたびに撮る（`flow` は毎回 host を
/// 作り直すので、スクロールが出ない）。
extension DesignFlowSnapshotTests {
  func testBoardScroll() throws {
    let size = NSSize(width: 640, height: 112)
    let glyphCycle: [AgentStateIcon.Kind?] = [.working, .waiting, .done, nil]
    let model = StatusRowModel()
    model.workspace = "Home"
    model.boardLabel = "Home"
    model.strip = TabStrip(
      titles: (0..<16).map { "task-\($0)" },
      glyphs: (0..<16).map { glyphCycle[$0 % glyphCycle.count] })
    model.selection = .board

    let appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingView(
      rootView: ZStack(alignment: .top) {
        BackgroundGlow()
        StatusRowView(model: model).frame(width: size.width, height: Chrome.barHeight)
      }
      .frame(width: size.width, height: size.height, alignment: .top))
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = appearance
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host

    let dir = previewDir("flows")
    let steps: [(String, StatusRowModel.Selection)] = [
      ("board", .board), ("last_tab", .tab(15)), ("board_again", .board), ("first_tab", .tab(0)),
    ]
    for (idx, (label, selection)) in steps.enumerated() {
      model.selection = selection
      host.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: rep)
      let url = dir.appendingPathComponent(String(format: "board_scroll_%02d_%@.png", idx, label))
      try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }
}

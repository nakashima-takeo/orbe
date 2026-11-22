import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// タブ行を実際に描画（NSHostingView に載せて layout）した状態でタブ集合を減らし、SwiftUI の入れ子
/// ForEach の子更新が古いセグメント構造で新しいタブ集合を引かず、行が新しい集合を描くことを固定する。
///
/// 壊れると何が起きるか。単独セグメントのタブを閉じる（タブ数もセグメント数も減る）と、
/// 「タブ集合」と「セグメント構造」を View が別々の observable から読む構造では、子更新が
/// 古い index で新しい配列を引いて Index out of range で即死する。純関数テストでは描画経路が
/// 走らないため、ここだけが検出できる。
@MainActor
final class StatusRowViewRenderTests: OrbeTestCase {
  private func snapshot(_ keys: [String], active: Int) -> StatusRowModel.Snapshot {
    var segments: [Range<Int>] = []
    var start = 0
    for i in keys.indices where i + 1 == keys.count || keys[i + 1] != keys[i] {
      segments.append(start..<(i + 1))
      start = i + 1
    }
    return StatusRowModel.Snapshot(
      workspace: "ws",
      strip: TabStrip(
        titles: keys, tabIds: Array(keys.indices), segments: segments,
        colorIndices: segments.map { WorktreeColor.index(forKey: keys[$0.lowerBound]) }),
      selection: .tab(active), boardLabel: nil, location: nil, rollup: [])
  }

  /// タブ行を並べない窓に載せて描く。
  private func host(_ model: StatusRowModel) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: Self.offscreenOrigin, size: NSSize(width: 800, height: 500)),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let hosting = NSHostingView(rootView: StatusRowView(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 800, height: Chrome.barHeight)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    return holdUntilTestEnds(window)
  }

  /// 描いているタブの枚数（タブ 1 枚に中クリックの受け口が 1 つ載る）。
  private func drawnTabs(_ window: NSWindow) -> Int {
    func count(_ view: NSView) -> Int {
      (view is MiddleClickCatcher.CatcherView ? 1 : 0) + view.subviews.reduce(0) { $0 + count($1) }
    }
    return window.contentView.map(count) ?? 0
  }

  /// [home][alpha][beta beta][plain] から単独セグメント alpha を閉じる（タブ数・セグメント数とも減る）。
  func testClosingSingletonSegmentWhileRenderedDrawsTheRemainingTabs() {
    let model = StatusRowModel()
    model.update(snapshot(["home", "alpha", "beta", "beta", "plain"], active: 1))
    let window = host(model)
    XCTAssertEqual(drawnTabs(window), 5, "前提: 5 枚を描いている")

    model.update(snapshot(["home", "beta", "beta", "plain"], active: 1))
    window.contentView?.layoutSubtreeIfNeeded()

    XCTAssertEqual(drawnTabs(window), 4, "閉じた後の 4 枚を描く")
  }
}

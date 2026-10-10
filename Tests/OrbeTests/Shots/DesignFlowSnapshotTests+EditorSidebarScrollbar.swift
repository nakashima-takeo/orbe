import OrbeEditorCore
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// サイドバーの一覧のつまみ（design-system §5 Explorer / Search panel）: 縦に溢れたツリーと検索結果で、操作していない
/// ときは何も出ず、位置を変えると幅 10 の矩形のつまみだけが出て（トラックの地・枠なし）、ポインタが一覧の上にある間は
/// 見え続け（つまみの上では色が上がる）、止まってしばらく・ポインタが出たらすぐ消え始める。位置を変えた状態は面を付けた
/// 窓の中でしか保てないので、reveal と同じく窓の中でそのまま描く。
extension DesignFlowSnapshotTests {
  func testEditorSidebarScrollbar() throws {
    let queriesRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    let scene = try EditorShellFixtures.scene(queriesRoot: queriesRoot, in: TestScratch.caseDir)
    defer { scene.cleanup() }
    scene.warmUp()
    pumpMain(until: { scene.isReady }, "git バッジが揃う")
    let pane = scene.pane
    let deep = try XCTUnwrap(
      scene.tab.editor.documents.first { $0.url.lastPathComponent == "FileTree.swift" })
    scene.warmUp(size: NSSize(width: 1100, height: 240))
    pane.window?.appearance = NSAppearance(named: .darkAqua)
    let settle = { RunLoop.main.run(until: Date().addingTimeInterval(1.6)) }
    let steps: [(label: String, action: () -> Void)] = [
      (
        "tree_rest",
        {
          scene.tab.editor.activate(deep)  // 深い行まで開いてツリーを溢れさせる
          settle()
        }
      ),
      ("tree_scrolled", { self.scrollTree(pane, to: 40) }),
      (
        "tree_pointer_on_thumb",
        {
          self.pointer(pane, onTreeThumb: true)
          settle()
        }
      ),
      (
        "tree_faded",
        {
          self.pointer(pane, onTreeThumb: false)
          settle()
        }
      ),
      (
        "search_rest",
        {
          scene.search(SearchQuery(pattern: "self"))
          pumpMain(until: { scene.isSearchDone }, "検索が終わる")
          settle()
        }
      ),
      ("search_scrolled", { self.scroll(pane.searchResults, to: 120) }),
      (
        "search_scrolled_light",
        {
          pane.window?.appearance = NSAppearance(named: .aqua)
          self.scroll(pane.searchResults, to: 160)  // 撮る間に消え始めないよう、もう一度送る
        }
      ),
      ("search_faded", settle),
    ]
    try shootInWindow(pane, "editor_sidebar_scrollbar", steps: steps)
  }

  private func shootInWindow(
    _ pane: EditorPaneView, _ name: String, steps: [(label: String, action: () -> Void)]
  ) throws {
    for (idx, step) in steps.enumerated() {
      step.action()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let rep = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
      pane.cacheDisplay(in: pane.bounds, to: rep)
      let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
      let url = previewDir("flows").appendingPathComponent(
        String(format: "%@_%02d_%@.png", name, idx, step.label))
      try data.write(to: url)
      print("[flow] wrote \(url.path)")
    }
  }

  private func scroll(_ scroll: NSScrollView, to y: CGFloat) {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  private func scrollTree(_ pane: EditorPaneView, to y: CGFloat) {
    if let tree = scrollView(in: pane.sideHost) { scroll(tree, to: y) }
  }

  /// ツリーのつまみの中央へポインタを入れる・一覧の外へ出す（SwiftUI のホバーはポインタの下の view が受ける
  /// mouseEntered / mouseMoved / mouseExited で動く）。
  private func pointer(_ pane: EditorPaneView, onTreeThumb inside: Bool) {
    guard let tree = scrollView(in: pane.sideHost), let document = tree.documentView,
      let window = pane.window
    else { return }
    let geometry = SidebarScrollbar.Metrics(
      position: tree.documentVisibleRect.minY, total: document.frame.height,
      visible: tree.documentVisibleRect.height
    ).geometry
    let point = tree.convert(
      NSPoint(
        x: tree.bounds.maxX - Theme.Layout.editorSidebarScrollbar / 2,
        y: geometry.sliderPosition + geometry.sliderLength / 2), to: nil)
    let host = pane.sideHost
    guard let target = host.hitTest(host.superview!.convert(point, from: nil)) else { return }
    let event = NSEvent.mouseEvent(
      with: .mouseMoved, location: inside ? point : NSPoint(x: -10, y: -10), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    if inside {
      target.mouseEntered(with: event)
      target.mouseMoved(with: event)
    } else {
      target.mouseExited(with: event)
    }
  }
}

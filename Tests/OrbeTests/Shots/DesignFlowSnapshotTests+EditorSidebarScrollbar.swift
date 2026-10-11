import OrbeEditorCore
import OrbeTestSupport
import SwiftUI
import XCTest

@testable import Orbe

/// サイドバーの一覧のつまみ（design-system §5 Explorer / Search panel）: 縦に溢れたツリーと検索結果で、操作していない
/// ときは何も出ず、位置を変えると幅 10 の矩形のつまみだけが出て（トラックの地・枠なし）、ポインタが一覧の上にある間は
/// 見え続け（つまみの上では色が上がる）、止まってしばらく・ポインタが出たらすぐ消え始める。一番下まで送ると最後の行の
/// 下に 1 行分の空きが残る。位置を変えた状態は面を付けた
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
      ("tree_end", { self.scrollTreeToEnd(pane) }),  // 最後の行の下に 1 行分の空き
      (
        "search_rest",
        {
          scene.search(SearchQuery(pattern: "self"))
          pumpMain(until: { scene.isSearchDone }, "検索が終わる")
          settle()
        }
      ),
      ("search_scrolled", { self.scroll(pane.searchResults, to: 120) }),
      ("search_end", { pane.searchResults.list.scrollToEndOfDocument(nil) }),  // End
      (
        "search_end_light",
        {
          pane.window?.appearance = NSAppearance(named: .aqua)
          self.scroll(pane.searchResults, to: 0)  // 撮る間に消え始めないよう、送り直す
          pane.searchResults.list.scrollToEndOfDocument(nil)
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

  private func scrollTreeToEnd(_ pane: EditorPaneView) {
    guard let tree = scrollView(in: pane.sideHost), let document = tree.documentView else { return }
    scroll(tree, to: document.frame.height - tree.documentVisibleRect.height)
  }

  /// ツリーのつまみの中央へポインタを入れる・一覧の外へ出す。
  private func pointer(_ pane: EditorPaneView, onTreeThumb inside: Bool) {
    guard let thumb = treeThumbFrame(pane) else { return }
    let center = pane.convert(NSPoint(x: thumb.midX, y: thumb.midY), from: nil)
    if inside {
      movePointer(pane, to: center, over: pane.sideHost)
    } else {
      movePointerOut(pane, from: center, over: pane.sideHost)
    }
  }
}
